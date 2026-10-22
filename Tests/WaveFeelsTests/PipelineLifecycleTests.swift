import AppKit
import Foundation
import Testing
import WaveCore
@testable import WaveFeels

/// Приложение работает днями: запуски и остановки конвейера не должны оставлять анализ, демо или
/// второго писателя в кольце; сон и пробуждение перезапускают источник звука.
@MainActor
struct PipelineLifecycleTests {
    static let cycles = 20

    @Test func demoStartStopCyclesLeakNothing() throws {
        let processes = AudioProcessList()
        let output = OutputDeviceMonitor()
        for cycle in 0..<Self.cycles {
            weak var weakPipeline: AudioPipeline?
            weak var weakEngine: AnalysisEngine?
            weak var weakFirstDemo: DemoAudioSource?
            weak var weakSecondDemo: DemoAudioSource?
            var ring: SampleRingBuffer?

            try autoreleasepool {
                let pipeline = AudioPipeline(store: FrameStore(), processes: processes, output: output)
                weakPipeline = pipeline
                weakEngine = pipeline.analysisEngineForTesting
                ring = pipeline.ringForTesting

                try pipeline.startDemo(file: Self.demo)
                #expect(pipeline.status == .demo, "цикл \(cycle)")
                #expect(pipeline.analysisEngineForTesting.isRunning, "цикл \(cycle)")
                #expect(pipeline.ringForTesting.activeWriters == 1, "цикл \(cycle)")
                weakFirstDemo = pipeline.demoForTesting

                // Новое демо поверх идущего: прежнее останавливается раньше, чем пишет новое.
                try pipeline.startDemo(file: Self.demo)
                #expect(pipeline.ringForTesting.activeWriters == 1, "цикл \(cycle)")
                weakSecondDemo = pipeline.demoForTesting
                #expect(weakFirstDemo == nil, "цикл \(cycle): прежнее демо не освободилось")

                pipeline.stop()
                #expect(pipeline.status == .stopped, "цикл \(cycle)")
                #expect(!pipeline.analysisEngineForTesting.isRunning, "цикл \(cycle)")
                #expect(pipeline.demoForTesting == nil, "цикл \(cycle)")
            }

            #expect(weakSecondDemo == nil, "цикл \(cycle): DemoAudioSource не освободился")
            #expect(weakEngine == nil, "цикл \(cycle): AnalysisEngine не освободился")
            #expect(weakPipeline == nil, "цикл \(cycle): AudioPipeline не освободился")
            #expect(ring?.activeWriters == 0, "цикл \(cycle)")
            #expect((ring?.peakWriters ?? 0) <= 1, "цикл \(cycle): в кольце было два писателя")
        }
    }

    @Test func sleepStopsDemoAndWakeRestartsIt() async throws {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.sleep-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(defaults: defaults)
        model.start(arguments: LaunchArguments(demoFile: Self.demo, noCapture: true))
        defer { model.stop() }
        #expect(model.pipeline.status == .demo)

        model.systemWillSleep()
        #expect(model.pipeline.status == .stopped)
        #expect(model.pipeline.ringForTesting.activeWriters == 0)

        model.systemDidWake()
        // Запуск через `wakeDelay` (1 с), до этого источник стоит.
        #expect(model.pipeline.status == .stopped)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.pipeline.status != .demo, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.pipeline.status == .demo)
        #expect(model.pipeline.ringForTesting.activeWriters == 1)
        #expect(model.pipeline.ringForTesting.peakWriters <= 1)
    }

    @Test func screenLockSuppressesIsland() throws {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.lock-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(defaults: defaults)
        #expect(!model.islandSuppressed)
        model.screenLockChanged(true)
        #expect(model.screenLocked)
        #expect(model.islandSuppressed)
        model.screenLockChanged(false)
        #expect(!model.islandSuppressed)
    }

    /// `Resources/Demo/demo.wav` в корне репозитория.
    private static var demo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Demo/demo.wav")
    }
}
