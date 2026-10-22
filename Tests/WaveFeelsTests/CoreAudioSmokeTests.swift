import CoreAudio
import Foundation
import Synchronization
import Testing
import WaveCore
@testable import WaveFeels

/// Проверки без создания tap: на CI нет разрешения на запись звука, запрос TCC недопустим.
struct CoreAudioSmokeTests {
    @Test @MainActor func processListSnapshotHasValidPIDs() {
        let list = AudioProcessList()
        let processes = list.snapshot()
        #expect(processes.allSatisfy { $0.pid > 0 })
        #expect(processes.allSatisfy { $0.objectID != kAudioObjectUnknown })
    }

    @Test @MainActor func outputDeviceMonitorReadsDeviceOrUnknown() {
        let monitor = OutputDeviceMonitor()
        monitor.start()
        defer { monitor.stop() }
        if monitor.deviceID != kAudioObjectUnknown {
            #expect(!monitor.deviceUID.isEmpty)
        }
        #expect((0...1).contains(monitor.volume))
        #expect(monitor.effectiveVolume <= monitor.volume)
    }

    @Test func demoAudioDrivesAnalysis() async throws {
        let ring = SampleRingBuffer(capacity: 131_072)
        let store = FrameStore()
        let demo = try DemoAudioSource(ring: ring, file: Self.resource("demo.wav"))
        let engine = AnalysisEngine(ring: ring, store: store)
        let log = FrameLog()
        engine.observeFrames { log.append($0) }

        demo.start()
        engine.start(sampleRate: demo.sampleRate)
        #expect(engine.isRunning)
        // Удары демо идут каждые 0,5 с, детектору нужно 0,5 с истории: за 3 с ловятся удары
        // на 1,0, 1,5, 2,0 и 2,5 с. Лишние 0,2 с дают запас в один удар (3,0 с).
        try await Task.sleep(for: .seconds(3.2))
        engine.stop()
        demo.stop()

        let frames = log.frames
        #expect(!engine.isRunning)
        #expect(frames.count > 60)
        #expect(frames.contains { $0.level > 0.2 })
        let beats = frames.filter { $0.beat > 0.8 }.count
        #expect(beats >= 4, "кадров с beat > 0.8: \(beats)")
        #expect(store.latest == .silent)
    }

    @Test func silenceGrowsZeroRun() async throws {
        let ring = SampleRingBuffer(capacity: 131_072)
        let demo = try DemoAudioSource(ring: ring, file: Self.resource("silence.wav"))
        let engine = AnalysisEngine(ring: ring, store: FrameStore())

        demo.start()
        engine.start(sampleRate: demo.sampleRate)
        try await Task.sleep(for: .seconds(1.5))
        let zeroRun = engine.zeroRunDuration
        engine.stop()
        demo.stop()

        #expect(zeroRun > 1, "zeroRunDuration: \(zeroRun)")
    }

    /// Пока остров скрыт, анализ идет с частотой 15 Гц; признак переживает остановку и запуск.
    @Test func idleEngineTicksAtFifteenHertz() async throws {
        let ring = SampleRingBuffer(capacity: 131_072)
        let engine = AnalysisEngine(ring: ring, store: FrameStore())
        let log = FrameLog()
        engine.observeFrames { log.append($0) }

        engine.setIdle(true)
        engine.start(sampleRate: 48_000)
        #expect(engine.tickIntervalForTesting == 1 / AnalysisEngine.idleRate)
        // Конвейер перезапускает анализ при пересборке, а признак присылает только при смене.
        engine.stop()
        engine.start(sampleRate: 48_000)
        #expect(engine.tickIntervalForTesting == 1 / AnalysisEngine.idleRate)
        let clock = ContinuousClock()
        let before = log.frames.count
        let started = clock.now
        try await Task.sleep(for: .seconds(1))
        let idleFrames = log.frames.count - before
        let elapsed = clock.now - started
        // Сон под нагрузкой может затянуться, поэтому проверяется частота за фактическое время:
        // не больше 15 кадров в секунду (плюс первый сразу и запас на границы) и не меньше половины
        // этого: таймер работает, а не стоит.
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let expected = seconds * AnalysisEngine.idleRate
        let upper = Int(expected) + 3
        let lower = max(1, Int(expected * 0.5))
        #expect(idleFrames <= upper, "кадров в простое: \(idleFrames) за \(elapsed), не больше \(upper)")
        #expect(idleFrames >= lower, "кадров в простое: \(idleFrames) за \(elapsed), не меньше \(lower)")

        engine.setIdle(false)
        let active = engine.tickIntervalForTesting
        #expect(active == 1.0 / 60 || active == 1.0 / 30)
        engine.stop()
    }

    /// `Resources/Demo/<name>` в корне репозитория.
    private static func resource(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Demo/\(name)")
    }
}

private final class FrameLog: Sendable {
    private let storage = Mutex<[WaveFrame]>([])

    func append(_ frame: WaveFrame) {
        storage.withLock { $0.append(frame) }
    }

    var frames: [WaveFrame] {
        storage.withLock { $0 }
    }
}
