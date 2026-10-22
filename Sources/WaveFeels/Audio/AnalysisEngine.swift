import CoreAudio
import Foundation
import QuartzCore
import Synchronization
import WaveCore

/// Анализ по шагам на часах звука (`beat-sync.md` 2.2).
///
/// Таймер только будит очередь анализа: 120 Гц, пока остров виден (онсет ждет пробуждения в
/// среднем 4 мс вместо 8), 30 Гц в режиме энергосбережения, 15 Гц, пока остров скрыт. Каждое
/// пробуждение обрабатывает все полные шаги `StreamAnalyzer` (256 сэмплов при 48 кГц), пришедшие
/// с прошлого, поэтому число шагов в секунду от частоты таймера не зависит, а время каждого шага
/// берется из номера сэмпла.
///
/// Время хоста сэмпла дает `HostClock`: метка последнего блока кольца (`RingStamp`, тики хоста из
/// IOProc или демо) переводится в секунды хоста тем же отсчетом, что у `CACurrentMediaTime()`.
/// Без меток (запись без времени) линия ставится по `(totalWritten, сейчас)` на каждом пробуждении.
/// Кадр шага публикуется в `FrameStore` на слышимое время центра окна:
/// `H(n_centre) + outputLatency + syncOffset`. Расписание свечения `BeatTracker` переводится с оси
/// потока на ту же ось: `H(e) - e / rate + outputLatency + syncOffset`.
///
/// Отставание больше 0.5 с (сон, остановка очереди) сбрасывает анализ и трекер и продолжает с самого
/// нового шага. Если в кольцо больше 250 мс не приходят сэмплы (`SampleFeedMonitor`), публикуется
/// тихий кадр на слышимое время конца потока, анализ и трекер начинаются заново. Пока остров скрыт,
/// обрабатывается только самый новый шаг на пробуждение, уровни и сглаживание идут на время с
/// прошлого пробуждения, трекер стоит, расписание пустое.
///
/// `zeroRunDuration` растет, если поток встал или все окна пробуждения из точных нулей, и
/// обнуляется на любом ненулевом окне; пробуждение без нового шага при живом потоке его не
/// меняет (блоки IOProc приходят реже пробуждений). Прибавка это время с прошлого пробуждения,
/// которое его меняло. По нему работает сторож нулей. Остров снова виден: состояние онсетов
/// начинается заново (`StreamAnalyzer.resetOnsets()`), уровни остаются.
/// `stop()` оставляет в хранилище один тихий кадр.
nonisolated final class AnalysisEngine: @unchecked Sendable {
    /// Самый большой шаг времени между пробуждениями, который получают уровни.
    static let maxStep = 0.1
    /// Самая большая прибавка `zeroRunDuration` за одно пробуждение, с: больше паузы между
    /// пробуждениями, которые его меняют, при живом потоке не бывает (поток встает через 250 мс).
    static let maxZeroRunStep = 0.5
    /// Частота пробуждений, пока остров виден, Гц.
    static let visibleRate = 120.0
    /// Частота пробуждений в режиме энергосбережения, Гц.
    static let lowPowerRate = 30.0
    /// Частота пробуждений, пока остров скрыт, Гц.
    static let idleRate = 15.0
    /// Отставание анализа от кольца, после которого он прыгает к самому новому шагу, с.
    static let maxBacklog = 0.5

    private struct Shared: Sendable {
        var settings = LevelSettings()
        var outputLatency = 0.0
        var syncOffset = 0.0
        var isRunning = false
        var zeroRun: Double = 0
        var hopsProcessed = 0
        var frameObserver: (@Sendable (WaveFrame, Double) -> Void)?
    }

    private let ring: SampleRingBuffer
    private let store: FrameStore
    private let wakesOnTimer: Bool
    private let queue = DispatchQueue(label: "com.wfeels.wavefeels.analysis", qos: .userInteractive)
    private let shared = Mutex(Shared())

    // Только на queue.
    private let analyzer: StreamAnalyzer
    private var tracker: BeatTracker
    private var hostClock = HostClock(sampleRate: 48_000)
    private var window: [Float]
    private var timer: DispatchSourceTimer?
    private var powerObserver: (any NSObjectProtocol)?
    private var feed = SampleFeedMonitor()
    /// Конец следующего шага по номеру сэмпла; `nil`: первое пробуждение начнет с самого нового.
    private var nextHopEnd: Int?
    private var lastStamp: RingStamp?
    /// Линия часов стоит по `(totalWritten, сейчас)`, а не по метке: первая метка ставит ее заново.
    private var fallbackAnchored = false
    private var lastWake: Double?
    /// Последнее пробуждение, которое меняло `zeroRun`.
    private var lastZeroRunWake: Double?
    private var feedStalled = false
    private var active = false
    private var interval = 1 / AnalysisEngine.visibleRate
    private var idle = false

    /// `wakesOnTimer: false`: без таймера, пробуждения только через `processPendingForTesting`.
    init(ring: SampleRingBuffer, store: FrameStore, wakesOnTimer: Bool = true) {
        self.ring = ring
        self.store = store
        self.wakesOnTimer = wakesOnTimer
        let analyzer = StreamAnalyzer(sampleRate: 48_000)
        self.analyzer = analyzer
        tracker = BeatTracker(framesPerSecond: analyzer.config.framesPerSecond)
        window = [Float](repeating: 0, count: analyzer.config.fftSize)
    }

    var isRunning: Bool { shared.withLock { $0.isRunning } }

    /// Сколько секунд подряд поток стоит, новых шагов нет или все окна из точных нулей.
    var zeroRunDuration: Double { shared.withLock { $0.zeroRun } }

    /// Запускает анализ: поток начинается заново с самого нового шага, часы хоста ждут метки,
    /// хранилище держит тихий кадр. Другая частота перенастраивает анализатор и трекер (id событий
    /// продолжают расти), та же сбрасывает их.
    func start(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        queue.sync {
            if self.analyzer.config.sampleRate != rate {
                self.analyzer.reconfigure(sampleRate: rate)
                self.tracker.reconfigure(framesPerSecond: self.analyzer.config.framesPerSecond)
                self.window = [Float](repeating: 0, count: self.analyzer.config.fftSize)
            } else {
                self.analyzer.reset()
                self.tracker.reset()
            }
            self.restartStream()
            self.lastWake = nil
            self.lastZeroRunWake = nil
            self.active = true
            self.shared.withLock {
                $0.zeroRun = 0
                $0.isRunning = true
            }
            if self.wakesOnTimer, self.timer == nil {
                let timer = DispatchSource.makeTimerSource(flags: [], queue: self.queue)
                timer.setEventHandler { [weak self] in
                    self?.wake(now: CACurrentMediaTime())
                }
                self.timer = timer
                self.applyInterval()
                timer.resume()
                self.observePowerState()
            }
        }
    }

    func stop() {
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.lastWake = nil
            self.lastZeroRunWake = nil
            self.active = false
            if let observer = self.powerObserver {
                NotificationCenter.default.removeObserver(observer)
                self.powerObserver = nil
            }
            self.shared.withLock { $0.isRunning = false }
        }
        store.reset()
    }

    /// Уровни, задержка вывода `L_out` и сдвиг синхронизации `u` в секундах. Нечисловые
    /// задержка и сдвиг считаются нулем.
    func update(settings: LevelSettings, outputLatency: Double, syncOffset: Double) {
        shared.withLock {
            $0.settings = settings
            $0.outputLatency = outputLatency.isFinite ? outputLatency : 0
            $0.syncOffset = syncOffset.isFinite ? syncOffset : 0
        }
    }

    /// Остров скрыт: пробуждения реже, по одному шагу, трекер стоит, расписание пустое.
    /// Применяется на очереди анализа, сохраняется между запусками.
    func setIdle(_ idle: Bool) {
        queue.async { [weak self] in
            guard let self, self.idle != idle else { return }
            self.idle = idle
            if idle {
                self.tracker.reset()
                self.store.publishSchedule(.empty)
            } else {
                // В простое следящие пики онсетов спадали за пробуждение 15 Гц и могли остаться
                // завышенными: без сброса бочки терялись бы еще секунды после появления острова.
                self.analyzer.resetOnsets()
            }
            self.applyInterval()
        }
    }

    /// Текущий шаг таймера, с. Для тестов.
    var tickIntervalForTesting: Double { queue.sync { interval } }

    /// Сколько шагов обработано с создания. Для тестов.
    var hopsProcessedForTesting: Int { shared.withLock { $0.hopsProcessed } }

    /// Одно пробуждение на момент `now` (секунды хоста), синхронно. Для тестов с
    /// `wakesOnTimer: false`.
    func processPendingForTesting(now: Double) {
        queue.sync { self.wake(now: now) }
    }

    /// Вызывается на очереди анализа для каждого опубликованного кадра вместе с его слышимым
    /// временем (секунды хоста). Для тестов и диагностики.
    func observeFrames(_ observer: (@Sendable (WaveFrame, Double) -> Void)?) {
        shared.withLock { $0.frameObserver = observer }
    }

    // MARK: - Очередь анализа

    /// Поток начинается заново: часы хоста без метки, первый шаг самый новый, в хранилище тихий
    /// кадр и пустое расписание.
    private func restartStream() {
        hostClock.reset(sampleRate: analyzer.config.sampleRate)
        nextHopEnd = nil
        lastStamp = nil
        fallbackAnchored = false
        feed.reset()
        feedStalled = false
        store.reset()
    }

    private func wake(now: Double) {
        guard active, now.isFinite else { return }
        let (settings, latency, syncOffset, observer) = shared.withLock {
            ($0.settings, $0.outputLatency, $0.syncOffset, $0.frameObserver)
        }
        var dt = interval
        if let lastWake {
            dt = max(now - lastWake, 0)
        }
        dt = min(dt, Self.maxStep)
        lastWake = now

        let config = analyzer.config
        let total = ring.totalWritten
        if let next = nextHopEnd, total < next - config.hopSize {
            // Кольцо обнулено (пересборка tap, новое демо): поток начинается заново.
            analyzer.reset()
            tracker.reset()
            restartStream()
        }

        if let stamp = ring.latestStamp() {
            if stamp != lastStamp {
                if fallbackAnchored {
                    // Метка точнее линии по часам пробуждений: она ставит линию заново.
                    hostClock.reset(sampleRate: config.sampleRate)
                    fallbackAnchored = false
                }
                let seconds = Double(AudioConvertHostTimeToNanos(stamp.hostTicks)) / 1_000_000_000
                hostClock.anchor(sampleIndex: stamp.sampleIndex, hostSeconds: seconds)
                lastStamp = stamp
            }
        } else {
            // Писатель не дает времени: последний записанный сэмпл считается взятым сейчас.
            hostClock.anchor(sampleIndex: total, hostSeconds: now)
            fallbackAnchored = true
        }

        let offset = latency + syncOffset
        let windows: Windows
        if feed.update(totalWritten: total, now: now) {
            // Новых сэмплов нет: волны гаснут, а не застывают на последнем окне.
            if !feedStalled {
                analyzer.reset()
                tracker.reset()
                store.publishSchedule(.empty)
                feedStalled = true
            }
            let time = (hostClock.hostTime(ofSample: total) ?? now) + offset
            store.publish(.silent, at: time)
            observer?(.silent, time)
            windows = .zero
        } else {
            feedStalled = false
            windows = processHops(
                total: total, dt: dt, settings: settings, offset: offset, observer: observer
            )
        }
        guard windows != .noHop else { return }
        var step = interval
        if let lastZeroRunWake {
            step = max(now - lastZeroRunWake, 0)
        }
        step = min(step, Self.maxZeroRunStep)
        lastZeroRunWake = now
        shared.withLock { $0.zeroRun = windows == .zero ? $0.zeroRun + step : 0 }
    }

    /// Что дали окна пробуждения: нового шага нет, все из точных нулей (или поток встал), есть звук.
    private enum Windows {
        case noHop, zero, sound
    }

    /// Все полные шаги до `total` (скрытый остров: только самый новый).
    private func processHops(
        total: Int,
        dt: Double,
        settings: LevelSettings,
        offset: Double,
        observer: (@Sendable (WaveFrame, Double) -> Void)?
    ) -> Windows {
        let config = analyzer.config
        let hop = config.hopSize
        guard total >= config.fftSize else { return .noHop }
        var end = nextHopEnd ?? total
        if idle {
            if end < total {
                end += (total - end) / hop * hop
            }
        } else if Double(total - end) > Self.maxBacklog * config.sampleRate {
            // Анализ отстал (сон, остановленная очередь): старые шаги уже не нужны.
            end += (total - end) / hop * hop
            analyzer.reset()
            tracker.reset()
        }

        var processed = 0
        var allZero = true
        var lastEnd: Int?
        while end <= total {
            let hopEnd = end
            end += hop
            let copied = window.withUnsafeMutableBufferPointer { ring.copyWindow(endingAt: hopEnd, into: $0) }
            guard copied, let centre = hostClock.hostTime(ofSample: hopEnd - config.fftSize / 2) else { continue }
            allZero = allZero && window.allSatisfy { $0 == 0 }
            let result = window.withUnsafeBufferPointer {
                analyzer.processHop(window: $0, endSample: hopEnd, settings: settings, dt: idle ? dt : nil)
            }
            if !idle {
                tracker.process(result)
            }
            let time = centre + offset
            store.publish(result.frame, at: time)
            observer?(result.frame, time)
            processed += 1
            lastEnd = hopEnd
            if idle { break }
        }
        nextHopEnd = end
        if processed > 0 {
            shared.withLock { $0.hopsProcessed += processed }
        }
        if !idle, let lastEnd, let host = hostClock.hostTime(ofSample: lastEnd) {
            let shift = host - Double(lastEnd) / config.sampleRate + offset
            store.publishSchedule(tracker.schedule.shifted(by: shift))
        }
        if processed == 0 { return .noHop }
        return allZero ? .zero : .sound
    }

    private func applyInterval() {
        if idle {
            interval = 1 / Self.idleRate
        } else {
            interval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 / Self.lowPowerRate : 1 / Self.visibleRate
        }
        let nanos = Int(interval * 1_000_000_000)
        timer?.schedule(deadline: .now(), repeating: .nanoseconds(nanos), leeway: .milliseconds(1))
    }

    private func observePowerState() {
        guard powerObserver == nil else { return }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.powerStateChanged()
        }
    }

    private func powerStateChanged() {
        queue.async { [weak self] in
            self?.applyInterval()
        }
    }
}
