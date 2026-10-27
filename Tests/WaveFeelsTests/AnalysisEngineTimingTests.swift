import CoreAudio
import Foundation
import Synchronization
import Testing
import WaveCore
@testable import WaveFeels

/// Анализ по шагам на часах хоста без таймера и без сна: кольцо получает блоки по 512 сэмплов
/// с метками времени (как IOProc), пробуждения идут на смоделированном времени через
/// `processPendingForTesting(now:)`.
///
/// Время хоста сэмпла n: `hostStart + n / rate`. Блок пишется, когда его последний сэмпл уже
/// «прозвучал» к моменту пробуждения, метка блока это время его первого сэмпла в тиках хоста.
struct AnalysisEngineTimingTests {
    static let rate = 48_000.0
    static let blockSize = 512
    static let hostStart = 5_000.25
    static let outputLatency = 0.020
    static let syncOffset = 0.015
    /// Первая доля клик-трека, с потока.
    static let firstBeat = 0.25
    static let beatPeriod = 0.5

    // MARK: - Сигнал и запись

    /// Сэмпл `n` клик-трека 120 BPM: на каждой доле 20 мс синуса 60 Гц амплитуды 0.9 с затуханием 10 мс.
    static func click(_ n: Int) -> Float {
        let first = Int((firstBeat * rate).rounded())
        let period = Int((beatPeriod * rate).rounded())
        guard n >= first else { return 0 }
        let k = (n - first) % period
        guard k < Int(0.020 * rate) else { return 0 }
        let t = Double(k) / rate
        return 0.9 * Float(exp(-t / 0.010) * sin(2 * Double.pi * 60 * t))
    }

    static func host(_ sample: Int, start: Double = hostStart) -> Double {
        start + Double(sample) / rate
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        AudioConvertNanosToHostTime(UInt64((seconds * 1_000_000_000).rounded()))
    }

    /// Пишет в кольцо все блоки, последний сэмпл которых не позже `now`.
    struct Feeder {
        let ring: SampleRingBuffer
        var stamped = true
        /// Начало оси хоста этого потока (после `ring.reset()` новый поток).
        var start = AnalysisEngineTimingTests.hostStart
        var written = 0
        var signal: (Int) -> Float = { AnalysisEngineTimingTests.click($0) }
        private var block = [Float](repeating: 0, count: AnalysisEngineTimingTests.blockSize)

        init(ring: SampleRingBuffer) {
            self.ring = ring
        }

        mutating func feed(until now: Double) {
            let size = AnalysisEngineTimingTests.blockSize
            while AnalysisEngineTimingTests.host(written + size - 1, start: start) <= now {
                for i in 0..<size {
                    block[i] = signal(written + i)
                }
                let first = written
                let stampTicks = AnalysisEngineTimingTests.ticks(AnalysisEngineTimingTests.host(first, start: start))
                block.withUnsafeBufferPointer {
                    if stamped {
                        ring.write($0, hostTicks: stampTicks)
                    } else {
                        ring.write($0)
                    }
                }
                written += size
            }
        }
    }

    /// Движок без таймера с задержкой вывода и сдвигом синхронизации теста.
    static func makeEngine() -> (AnalysisEngine, SampleRingBuffer, FrameStore, TimedFrameLog) {
        let ring = SampleRingBuffer(capacity: 131_072)
        let store = FrameStore()
        let engine = AnalysisEngine(ring: ring, store: store, wakesOnTimer: false)
        let log = TimedFrameLog()
        engine.observeFrames { frame, time in log.append(frame, time) }
        engine.update(settings: LevelSettings(), outputLatency: outputLatency, syncOffset: syncOffset)
        engine.start(sampleRate: rate)
        return (engine, ring, store, log)
    }

    /// Расстояние от `time` (секунды потока) до ближайшей доли клик-трека.
    static func gridDistance(_ time: Double) -> Double {
        let phase = (time - firstBeat).truncatingRemainder(dividingBy: beatPeriod)
        let wrapped = phase < 0 ? phase + beatPeriod : phase
        return min(wrapped, beatPeriod - wrapped)
    }

    // MARK: - Тесты

    /// 6 с клик-трека, пробуждения 120 Гц: каждый кадр несет `H(n_centre) + outputLatency + syncOffset`,
    /// шагов ровно столько, сколько сэмплов пришло, деленное на 256, расписание лежит на сетке долей.
    @Test func framesCarryAudibleTimeAndScheduleFollowsClicks() throws {
        let (engine, ring, store, log) = Self.makeEngine()
        var feeder = Feeder(ring: ring)
        let offset = Self.outputLatency + Self.syncOffset

        var firstEnd: Int?
        var hops = engine.hopsProcessedForTesting
        var previousTotal = 0
        var badHopCounts = 0
        for wake in 1...720 {
            let now = Self.hostStart + 0.0007 + Double(wake) / 120
            feeder.feed(until: now)
            engine.processPendingForTesting(now: now)
            let total = ring.totalWritten
            let processed = engine.hopsProcessedForTesting - hops
            hops = engine.hopsProcessedForTesting
            if firstEnd == nil, total >= 1024 {
                // Первое пробуждение начинает с самого нового полного шага.
                firstEnd = total
                #expect(processed == 1)
            } else if firstEnd != nil, processed != (total - previousTotal) / 256 {
                badHopCounts += 1
            }
            previousTotal = total
        }
        let start = try #require(firstEnd)
        #expect(badHopCounts == 0)
        #expect(hops == (ring.totalWritten - start) / 256 + 1)

        let times = log.times
        #expect(times.count == hops)
        var worst = 0.0
        for (k, time) in times.enumerated() {
            let end = start + 256 * k
            let expected = Self.host(end - 512) + offset
            worst = max(worst, abs(time - expected))
        }
        #expect(worst < 0.001, "наибольшее расхождение времени кадра \(worst) с")

        let schedule = store.schedule
        #expect(!schedule.events.isEmpty)
        #expect(schedule.locked, "уверенность \(schedule.confidence)")
        let bpm = try #require(schedule.bpm)
        #expect(abs(bpm - 120) < 5, "темп \(bpm)")
        for event in schedule.events {
            let stream = event.time - offset - Self.hostStart
            #expect(Self.gridDistance(stream) < 0.010, "событие \(event.id) в \(stream) с потока")
        }
    }

    /// Остров скрыт: ровно один шаг на пробуждение, расписание пустое.
    @Test func idleProcessesOneHopPerWake() {
        let (engine, ring, store, log) = Self.makeEngine()
        var feeder = Feeder(ring: ring)
        var now = Self.hostStart
        for _ in 0..<120 {
            now += 1.0 / 120
            feeder.feed(until: now)
            engine.processPendingForTesting(now: now)
        }
        engine.setIdle(true)
        var counts: [Int] = []
        var frames: [Int] = []
        for _ in 0..<30 {
            now += 1.0 / AnalysisEngine.idleRate
            feeder.feed(until: now)
            let hops = engine.hopsProcessedForTesting
            let logged = log.times.count
            engine.processPendingForTesting(now: now)
            counts.append(engine.hopsProcessedForTesting - hops)
            frames.append(log.times.count - logged)
        }
        #expect(counts.allSatisfy { $0 == 1 }, "шагов на пробуждение: \(counts)")
        #expect(frames.allSatisfy { $0 == 1 }, "кадров на пробуждение: \(frames)")
        #expect(store.schedule == .empty)
        engine.setIdle(false)
        #expect(engine.tickIntervalForTesting == 1 / AnalysisEngine.visibleRate || engine.tickIntervalForTesting == 1.0 / 30)
    }

    /// Писатель без меток (`write(_:)`): кадры все равно идут, время по `(totalWritten, сейчас)`.
    @Test func unstampedWritesStillProduceFrames() throws {
        let (engine, ring, _, log) = Self.makeEngine()
        var feeder = Feeder(ring: ring)
        feeder.stamped = false
        var now = Self.hostStart
        for _ in 0..<120 {
            now += 1.0 / 120
            feeder.feed(until: now)
            engine.processPendingForTesting(now: now)
        }
        #expect(ring.latestStamp() == nil)
        #expect(engine.hopsProcessedForTesting > 150)
        let last = try #require(log.times.last)
        let audibleNow = now + Self.outputLatency + Self.syncOffset
        #expect(last <= audibleNow + 0.001, "последний кадр \(last - audibleNow) с от слышимого сейчас")
        #expect(last >= audibleNow - 0.05, "последний кадр \(last - audibleNow) с от слышимого сейчас")
    }

    /// Кольцо обнулено (пересборка tap), затем пишется новый поток: анализ начинается заново, кадры
    /// идут по меткам нового потока.
    @Test func ringResetRestartsProcessing() throws {
        let (engine, ring, _, log) = Self.makeEngine()
        var feeder = Feeder(ring: ring)
        var now = Self.hostStart
        for _ in 0..<120 {
            now += 1.0 / 120
            feeder.feed(until: now)
            engine.processPendingForTesting(now: now)
        }
        let hopsBefore = engine.hopsProcessedForTesting
        #expect(hopsBefore > 150)

        ring.reset()
        feeder.written = 0
        feeder.start = now + 0.2
        now = feeder.start
        for _ in 0..<60 {
            now += 1.0 / 120
            feeder.feed(until: now)
            engine.processPendingForTesting(now: now)
        }
        let hopsAfter = engine.hopsProcessedForTesting - hopsBefore
        #expect(hopsAfter > 60, "шагов после сброса: \(hopsAfter)")
        // Последний шаг кончается на самом новом сэмпле: блоки по 512 кратны шагу.
        let last = try #require(log.times.last)
        let expected = Self.host(ring.totalWritten - 512, start: feeder.start) + Self.outputLatency + Self.syncOffset
        #expect(abs(last - expected) < 0.001, "последний кадр \(last - expected) с от ожидаемого")
    }

    /// Нули наращивают `zeroRunDuration` по времени от первого полного окна (около 1 с за 1 с),
    /// пробуждение без нового шага его не меняет, клик сбрасывает в 0.
    @Test func zeroRunGrowsOnZerosAndResetsOnClick() {
        let (engine, ring, _, _) = Self.makeEngine()
        var feeder = Feeder(ring: ring)
        feeder.signal = { _ in 0 }
        var now = Self.hostStart
        var firstHopWake: Double?
        var lastHopWake: Double?
        for _ in 0..<120 {
            now += 1.0 / 120
            feeder.feed(until: now)
            let hops = engine.hopsProcessedForTesting
            engine.processPendingForTesting(now: now)
            guard engine.hopsProcessedForTesting > hops else { continue }
            lastHopWake = now
            if firstHopWake == nil {
                firstHopWake = now
                // Первое пробуждение с окном прибавляет один период пробуждений.
                #expect(abs(engine.zeroRunDuration - 1.0 / 120) < 1e-9, "zeroRunDuration: \(engine.zeroRunDuration)")
            }
        }
        // Пробуждения без нового шага не прибавляют, но следующее с шагом считает время от
        // прошлого, которое меняло значение: сумма равна времени от первого окна.
        let expected = (lastHopWake ?? now) - (firstHopWake ?? now) + 1.0 / 120
        #expect(abs(engine.zeroRunDuration - expected) < 1e-6, "zeroRunDuration: \(engine.zeroRunDuration), ожидалось \(expected)")
        #expect(engine.zeroRunDuration > 0.95)

        // Новых блоков нет, поток жив (меньше 250 мс): значение не меняется.
        let steady = engine.zeroRunDuration
        engine.processPendingForTesting(now: now + 0.001)
        #expect(engine.zeroRunDuration == steady)

        // Клик в начале следующего блока.
        let clickStart = feeder.written
        feeder.signal = { n in
            let k = n - clickStart
            guard k >= 0, k < 960 else { return 0 }
            let t = Double(k) / 48_000
            return 0.9 * Float(exp(-t / 0.010) * sin(2 * Double.pi * 60 * t))
        }
        now = Self.host(feeder.written + Self.blockSize - 1)
        feeder.feed(until: now)
        engine.processPendingForTesting(now: now)
        #expect(engine.zeroRunDuration == 0)
    }
}

extension AnalysisEngineTimingTests {
    /// Режим «Свечения» доходит до трекера и анализатора вместе (`GlowMode.apply`): при создании и при
    /// смене на очереди анализа. Запуск на другой частоте и обнуление кольца его не сбрасывают.
    @Test func glowModeReachesTrackerAndAnalyzer() {
        let ring = SampleRingBuffer(capacity: 131_072)
        let engine = AnalysisEngine(ring: ring, store: FrameStore(), wakesOnTimer: false, glowMode: .sound)
        #expect(engine.glowModeForTesting.mode == .sound)
        #expect(engine.glowModeForTesting.measuresBassLevel)
        engine.setGlowMode(.rhythm)
        #expect(engine.glowModeForTesting.mode == .rhythm)
        #expect(!engine.glowModeForTesting.measuresBassLevel)
        engine.setGlowMode(.hybrid)
        engine.start(sampleRate: 44_100)
        engine.start(sampleRate: Self.rate)
        #expect(engine.glowModeForTesting.mode == .hybrid)
        #expect(engine.glowModeForTesting.measuresBassLevel)
        engine.stop()
        #expect(AnalysisEngine(ring: ring, store: FrameStore(), wakesOnTimer: false).glowModeForTesting.mode == .rhythm)
    }
}

/// Кадры и их слышимые времена с очереди анализа.
final class TimedFrameLog: Sendable {
    private let storage = Mutex<[(frame: WaveFrame, time: Double)]>([])

    func append(_ frame: WaveFrame, _ time: Double) {
        storage.withLock { $0.append((frame, time)) }
    }

    var times: [Double] {
        storage.withLock { $0.map(\.time) }
    }
}
