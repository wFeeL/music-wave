import Foundation
import Synchronization
import WaveCore

/// Таймер анализа: 60 Гц (30 Гц в режиме энергосбережения) берет из кольца окно 2048 сэмплов
/// со смещением на задержку, считает `Analyzer.process` и публикует кадр в `FrameStore`.
/// Пока остров скрыт (`setIdle(true)`), таймер идет с частотой 15 Гц: этого хватает, чтобы
/// `ActivityGate` заметил начало звука (лишние десятки миллисекунд), а волны не рисуются.
/// Если в кольцо больше 250 мс не приходят новые сэмплы (tap или демо встали), анализ получает
/// тишину: волны затухают, а не застывают на последнем окне, и это время идет в
/// `zeroRunDuration`, как нули (`SampleFeedMonitor`).
nonisolated final class AnalysisEngine: @unchecked Sendable {
    /// Самый большой шаг времени, который получает анализатор.
    static let maxStep = 0.1
    /// Частота анализа, пока остров скрыт, Гц.
    static let idleRate = 15.0

    private struct Shared: Sendable {
        var settings = LevelSettings()
        var delayFrames = 0
        var isRunning = false
        var zeroRun: Double = 0
        var frameObserver: (@Sendable (WaveFrame) -> Void)?
    }

    private let ring: SampleRingBuffer
    private let store: FrameStore
    private let queue = DispatchQueue(label: "com.wfeels.wavefeels.analysis", qos: .userInteractive)
    private let shared = Mutex(Shared())

    // Только на queue.
    private var analyzer: Analyzer?
    private var timer: DispatchSourceTimer?
    private var powerObserver: (any NSObjectProtocol)?
    private var window = [Float](repeating: 0, count: Analyzer.fftSize)
    private var feed = SampleFeedMonitor()
    private var lastTickNanos: UInt64?
    private var interval = 1.0 / 60
    private var idle = false

    init(ring: SampleRingBuffer, store: FrameStore) {
        self.ring = ring
        self.store = store
    }

    var isRunning: Bool { shared.withLock { $0.isRunning } }

    /// Сколько секунд подряд окно состоит из точных нулей (или данных в кольце нет).
    var zeroRunDuration: Double { shared.withLock { $0.zeroRun } }

    /// Запускает таймер. Если анализ уже идет с другой частотой, перенастраивает анализатор.
    func start(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        queue.sync {
            if let analyzer = self.analyzer {
                if analyzer.sampleRate != rate {
                    analyzer.reconfigure(sampleRate: rate)
                }
            } else {
                self.analyzer = Analyzer(sampleRate: rate)
            }
            self.lastTickNanos = nil
            self.feed.reset()
            self.shared.withLock {
                $0.zeroRun = 0
                $0.isRunning = true
            }
            if self.timer == nil {
                let timer = DispatchSource.makeTimerSource(flags: [], queue: self.queue)
                timer.setEventHandler { [weak self] in
                    self?.tick()
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
            self.lastTickNanos = nil
            if let observer = self.powerObserver {
                NotificationCenter.default.removeObserver(observer)
                self.powerObserver = nil
            }
            self.shared.withLock { $0.isRunning = false }
        }
        store.publish(.silent)
    }

    func update(settings: LevelSettings, delayFrames: Int) {
        shared.withLock {
            $0.settings = settings
            $0.delayFrames = max(0, delayFrames)
        }
    }

    /// Остров скрыт: анализ реже. Применяется на очереди анализа, сохраняется между запусками.
    func setIdle(_ idle: Bool) {
        queue.async { [weak self] in
            guard let self, self.idle != idle else { return }
            self.idle = idle
            self.applyInterval()
        }
    }

    /// Текущий шаг таймера, с. Для тестов.
    var tickIntervalForTesting: Double { queue.sync { interval } }

    /// Вызывается на очереди анализа для каждого опубликованного кадра. Для тестов и диагностики.
    func observeFrames(_ observer: (@Sendable (WaveFrame) -> Void)?) {
        shared.withLock { $0.frameObserver = observer }
    }

    // MARK: - Очередь анализа

    private func tick() {
        guard let analyzer else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var dt = interval
        if let last = lastTickNanos, now > last {
            dt = Double(now - last) / 1_000_000_000
        }
        dt = min(dt, Self.maxStep)
        lastTickNanos = now

        let (settings, delay, observer) = shared.withLock { ($0.settings, $0.delayFrames, $0.frameObserver) }
        let time = Double(now) / 1_000_000_000
        let stalled = feed.update(totalWritten: ring.totalWritten, now: time)
        let copied: Bool
        if stalled {
            // Новых сэмплов нет: последнее окно повторялось бы и держало волны в движении.
            window.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            copied = true
        } else {
            copied = window.withUnsafeMutableBufferPointer { buffer in
                ring.copyLatest(into: buffer, delay: delay)
            }
        }

        let frame: WaveFrame
        let isZero: Bool
        if copied {
            isZero = stalled || window.allSatisfy { $0 == 0 }
            frame = analyzer.process(samples: window, time: time, dt: dt, settings: settings)
        } else {
            isZero = true
            frame = .silent
        }
        shared.withLock { $0.zeroRun = isZero ? $0.zeroRun + dt : 0 }
        store.publish(frame)
        observer?(frame)
    }

    private func applyInterval() {
        if idle {
            interval = 1 / Self.idleRate
        } else {
            interval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 30 : 1.0 / 60
        }
        let nanos = Int(interval * 1_000_000_000)
        timer?.schedule(deadline: .now(), repeating: .nanoseconds(nanos), leeway: .milliseconds(2))
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
