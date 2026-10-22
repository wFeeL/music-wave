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
