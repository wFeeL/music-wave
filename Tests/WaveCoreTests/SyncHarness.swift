import Foundation
@testable import WaveCore

/// Модель всей цепочки свечения с подставными часами (`beat-sync.md` 3.2): блоки IOProc с метками
/// времени хоста, `HostClock`, пробуждения анализа по шагам, `StreamAnalyzer` и `BeatTracker`,
/// публикация расписания на ось хоста, рендер с `BeatGlow` на момент показа кадра.
///
/// Время хоста сэмпла n: `hostStart + n / rate`. Блок `[k·chunk, (k+1)·chunk)` приходит в момент
/// своего последнего сэмпла плюс дрожание и несет метку своего первого сэмпла плюс дрожание. Анализ
/// просыпается с частотой `wakeRate` (случайная фаза, дрожание), обрабатывает все полные шаги,
/// пришедшие к этому моменту, и публикует расписание, сдвинутое на
/// `hostClock(n) − n / rate + outputLatency + syncOffset`. Рендер с частотой `renderRate` (случайная
/// фаза) в момент `tEval` берет последнее расписание, опубликованное до него, и считает свечение на
/// момент показа `tP = tEval + 2 / renderRate`. Событие свечения это кадр, где свечение выросло больше
/// чем на 0.2 против прошлого кадра; его время это `tP` кадра.
///
/// Все времена в `SyncResult` отсчитываются от `hostStart`, то есть в секундах от первого сэмпла,
/// а слышимое время момента сцены t это `t + outputLatency`.
enum SyncHarness {
    struct Config: Sendable {
        var chunk = 512
        var chunkJitter = 0.0003
        var wakeRate = 120.0
        var wakeJitter = 0.002
        var renderRate = 60.0
        var outputLatency = 0.020
        var syncOffset = 0.0
        var trackerParameters = BeatTracker.Parameters()
        var seed: UInt64

        init(seed: UInt64 = 1) {
            self.seed = seed
        }
    }

    /// Начало оси хоста: не ноль, чтобы смешение осей потока и хоста было видно.
    static let hostStart = 7_345.25
    /// Сколько рендерить после конца звука.
    static let renderTail = 0.5
    /// Рост свечения за кадр, который считается вспышкой.
    static let eventRise: Float = 0.2

    static func run(scene: DrumScene, config: Config) -> SyncResult {
        let rate = scene.sampleRate
        var rng = TestRNG(seed: config.seed)
        let analyzer = StreamAnalyzer(sampleRate: rate)
        let fftSize = analyzer.config.fftSize
        let hopSize = analyzer.config.hopSize
        var tracker = BeatTracker(framesPerSecond: analyzer.config.framesPerSecond, parameters: config.trackerParameters)
        var clock = HostClock(sampleRate: rate)
        let settings = LevelSettings()

        // Блоки IOProc: момент прихода и метка первого сэмпла.
        let chunkCount = scene.samples.count / config.chunk
        var arrivals: [Double] = []
        var stamps: [Double] = []
        arrivals.reserveCapacity(chunkCount)
        stamps.reserveCapacity(chunkCount)
        for k in 0..<chunkCount {
            let last = hostStart + Double((k + 1) * config.chunk - 1) / rate
            let arrival = last + config.chunkJitter * Double(rng.nextUnit())
            arrivals.append(max(arrival, arrivals.last ?? arrival))
            stamps.append(hostStart + Double(k * config.chunk) / rate + config.chunkJitter * Double(rng.nextUnit()))
        }

        var delivered = 0
        var nextHopEnd = fftSize
        var published = BeatSchedule.empty
        var states: [SyncResult.State] = []

        let wakePeriod = 1 / config.wakeRate
        let wakePhase = wakePeriod * Double(rng.nextUnit() * 0.5 + 0.5)
        var wakeIndex = 0
        var lastWake = -Double.infinity
        func wakeTime(_ index: Int, _ rng: inout TestRNG) -> Double {
            let t = hostStart + wakePhase + Double(index) * wakePeriod + config.wakeJitter * Double(rng.nextUnit())
            return max(t, lastWake)
        }
        var pendingWake = wakeTime(0, &rng)

        func wake(at time: Double) {
            while delivered < chunkCount, arrivals[delivered] <= time {
                clock.anchor(sampleIndex: delivered * config.chunk, hostSeconds: stamps[delivered])
                delivered += 1
            }
            let available = delivered * config.chunk
            var processed: Int?
            scene.samples.withUnsafeBufferPointer { all in
                while nextHopEnd <= available {
                    let window = UnsafeBufferPointer(rebasing: all[(nextHopEnd - fftSize)..<nextHopEnd])
                    tracker.process(analyzer.processHop(window: window, endSample: nextHopEnd, settings: settings))
                    processed = nextHopEnd
                    nextHopEnd += hopSize
                }
            }
            guard let end = processed, let host = clock.hostTime(ofSample: end) else { return }
            let shift = host - Double(end) / rate + config.outputLatency + config.syncOffset
            published = tracker.schedule.shifted(by: shift)
            states.append(
                SyncResult.State(
                    time: time - hostStart, locked: published.locked, bpm: published.bpm,
                    confidence: published.confidence
                )
            )
        }

        let renderPeriod = 1 / config.renderRate
        let renderPhase = renderPeriod * Double(rng.nextUnit() * 0.5 + 0.5)
        let renderEnd = hostStart + Double(scene.samples.count) / rate + config.outputLatency + renderTail
        var glow = BeatGlow()
        var previous: Float = 0
        var events: [Double] = []
        var frame = 0
        while true {
            let tEval = hostStart + renderPhase + Double(frame) * renderPeriod
            guard tEval < renderEnd else { break }
            while pendingWake < tEval {
                wake(at: pendingWake)
                lastWake = pendingWake
                wakeIndex += 1
                pendingWake = wakeTime(wakeIndex, &rng)
            }
            let tP = tEval + 2 * renderPeriod
            let value = glow.value(at: tP, schedule: published, refreshPeriod: renderPeriod)
            if value - previous > eventRise {
                events.append(tP - hostStart)
            }
            previous = value
            frame += 1
        }

        return SyncResult(
            events: events,
            lockTime: states.first(where: \.locked)?.time,
            tempoBPM: states.last?.bpm,
            states: states,
            outputLatency: config.outputLatency
        )
    }
}

struct SyncResult: Sendable {
    /// Опубликованное состояние трекера.
    struct State: Sendable {
        /// Время публикации, секунды от первого сэмпла.
        var time: Double
        var locked: Bool
        var bpm: Double?
        var confidence: Double
    }

    /// Моменты показа кадров со вспышкой, секунды от первого сэмпла.
    var events: [Double]
    /// Первая публикация с захватом.
    var lockTime: Double?
    /// Темп последней публикации.
    var tempoBPM: Double?
    var states: [State]
    var outputLatency: Double

    /// Слышимые моменты для моментов сцены.
    func audible(_ times: [Double]) -> [Double] {
        times.map { $0 + outputLatency }
    }

    /// F-мера вспышек против `reference` (слышимые моменты) при взаимно однозначном жадном
    /// сопоставлении: пары в пределах `tolerance` берутся от самой близкой. Учитываются вспышки и
    /// эталоны с момента `from`.
    func fMeasure(reference: [Double], tolerance: Double, from: Double) -> Double {
        let seen = events.filter { $0 >= from }
        let truth = reference.filter { $0 >= from }
        guard !seen.isEmpty || !truth.isEmpty else { return 1 }
        let pairs = Self.match(seen, truth, tolerance: tolerance)
        return 2 * Double(pairs.count) / Double(seen.count + truth.count)
    }

    /// Средний сдвиг и его стандартное отклонение по сопоставленным парам (вспышка минус слышимый
    /// момент), с момента `from`.
    func offsets(reference: [Double], from: Double, tolerance: Double = 0.1) -> (mean: Double, sd: Double) {
        let pairs = Self.match(events.filter { $0 >= from }, reference.filter { $0 >= from }, tolerance: tolerance)
        let differences = pairs.map { $0.seen - $0.truth }
        guard !differences.isEmpty else { return (.nan, .nan) }
        let mean = differences.reduce(0, +) / Double(differences.count)
        let variance = differences.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(differences.count)
        return (mean, variance.squareRoot())
    }

    /// Число вспышек в отрезке.
    func events(in range: ClosedRange<Double>) -> Int {
        events.count(where: { range.contains($0) })
    }

    /// Первый момент не раньше `after`, когда опубликован захват с темпом, удовлетворяющим `tempo`.
    func lockTime(after: Double, tempo: (Double) -> Bool = { _ in true }) -> Double? {
        states.first { $0.time >= after && $0.locked && ($0.bpm.map(tempo) ?? false) }?.time
    }

    private static func match(_ seen: [Double], _ truth: [Double], tolerance: Double) -> [(seen: Double, truth: Double)] {
        let sortedTruth = truth.sorted()
        var candidates: [(distance: Double, seen: Int, truth: Int)] = []
        for (i, time) in seen.enumerated() {
            var low = 0
            var high = sortedTruth.count
            while low < high {
                let mid = (low + high) / 2
                if sortedTruth[mid] < time - tolerance { low = mid + 1 } else { high = mid }
            }
            var j = low
            while j < sortedTruth.count, sortedTruth[j] <= time + tolerance {
                candidates.append((abs(sortedTruth[j] - time), i, j))
                j += 1
            }
        }
        candidates.sort { $0.distance < $1.distance }
        var usedSeen = Set<Int>()
        var usedTruth = Set<Int>()
        var pairs: [(seen: Double, truth: Double)] = []
        for candidate in candidates where !usedSeen.contains(candidate.seen) && !usedTruth.contains(candidate.truth) {
            usedSeen.insert(candidate.seen)
            usedTruth.insert(candidate.truth)
            pairs.append((seen[candidate.seen], sortedTruth[candidate.truth]))
        }
        return pairs
    }
}
