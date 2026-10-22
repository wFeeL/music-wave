import AVFoundation
import AppKit
import Foundation
import Testing
import WaveCore
@testable import WaveFeels

/// Приложение работает днями: запуски и остановки конвейера не должны оставлять анализ, демо или
/// второго писателя в кольце; сон и пробуждение возвращают прежний режим. Тесты на главном
/// акторе уступают его между шагами, чтобы не задерживать соседние тесты с таймерами.
@Suite(.serialized)
@MainActor
struct PipelineLifecycleTests {
    static let cycles = 20
    /// Остановка не ждет очередь управления tap и не должна задерживать главный поток.
    static let maxStopDuration: Duration = .milliseconds(500)

    @Test func demoStartStopCyclesLeakNothing() async throws {
        let file = try Self.makeShortDemo()
        defer { try? FileManager.default.removeItem(at: file) }
        let processes = AudioProcessList()
        let output = OutputDeviceMonitor()
        let clock = ContinuousClock()
        for cycle in 0..<Self.cycles {
            weak var weakPipeline: AudioPipeline?
            weak var weakEngine: AnalysisEngine?
            weak var weakFirstDemo: DemoAudioSource?
            weak var weakSecondDemo: DemoAudioSource?
            var ring: SampleRingBuffer?
            var stopDuration: Duration = .zero

            try autoreleasepool {
                let pipeline = AudioPipeline(store: FrameStore(), processes: processes, output: output)
                weakPipeline = pipeline
                weakEngine = pipeline.analysisEngineForTesting
                ring = pipeline.ringForTesting

                try pipeline.startDemo(file: file)
                #expect(pipeline.status == .demo, "цикл \(cycle)")
                #expect(pipeline.analysisEngineForTesting.isRunning, "цикл \(cycle)")
                #expect(pipeline.ringForTesting.activeWriters == 1, "цикл \(cycle)")
                weakFirstDemo = pipeline.demoForTesting

                // Новое демо поверх идущего: прежнее останавливается раньше, чем пишет новое.
                try pipeline.startDemo(file: file)
                #expect(pipeline.ringForTesting.activeWriters == 1, "цикл \(cycle)")
                weakSecondDemo = pipeline.demoForTesting
                #expect(weakFirstDemo == nil, "цикл \(cycle): прежнее демо не освободилось")

                stopDuration = clock.measure {
                    pipeline.stop()
                }
                #expect(pipeline.status == .stopped, "цикл \(cycle)")
                #expect(!pipeline.analysisEngineForTesting.isRunning, "цикл \(cycle)")
                #expect(pipeline.demoForTesting == nil, "цикл \(cycle)")
                #expect(pipeline.waitForCaptureTeardown(timeout: 2), "цикл \(cycle)")
            }

            #expect(stopDuration < Self.maxStopDuration, "цикл \(cycle): stop() шел \(stopDuration)")
            #expect(weakSecondDemo == nil, "цикл \(cycle): DemoAudioSource не освободился")
            #expect(weakEngine == nil, "цикл \(cycle): AnalysisEngine не освободился")
            #expect(weakPipeline == nil, "цикл \(cycle): AudioPipeline не освободился")
            #expect(ring?.activeWriters == 0, "цикл \(cycle)")
            #expect((ring?.peakWriters ?? 0) <= 1, "цикл \(cycle): в кольце было два писателя")

            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func sleepRestoresDemoWithItsFile() throws {
        let file = try Self.makeShortDemo()
        defer { try? FileManager.default.removeItem(at: file) }
        let pipeline = AudioPipeline(store: FrameStore(), processes: AudioProcessList(), output: OutputDeviceMonitor())
        defer { pipeline.stop() }
        try pipeline.startDemo(file: file)

        let clock = ContinuousClock()
        let sleepDuration = clock.measure {
            pipeline.stopForSleep()
        }
        #expect(sleepDuration < Self.maxStopDuration)
        #expect(pipeline.status == .stopped)
        #expect(pipeline.ringForTesting.activeWriters == 0)
        // Второй сигнал сна до пробуждения не теряет запомненный режим.
        pipeline.stopForSleep()

        pipeline.restartAfterSleep()
        #expect(pipeline.status == .demo)
        #expect(pipeline.ringForTesting.activeWriters == 1)
        #expect(pipeline.ringForTesting.peakWriters <= 1)
    }

    @Test func sleepKeepsPausedDemoPaused() throws {
        let file = try Self.makeShortDemo()
        defer { try? FileManager.default.removeItem(at: file) }
        let pipeline = AudioPipeline(store: FrameStore(), processes: AudioProcessList(), output: OutputDeviceMonitor())
        defer { pipeline.stop() }
        pipeline.paused = true
        try pipeline.startDemo(file: file)
        #expect(pipeline.status == .paused)

        pipeline.stopForSleep()
        pipeline.restartAfterSleep()
        #expect(pipeline.status == .paused)
        #expect(pipeline.ringForTesting.activeWriters == 0)

        pipeline.paused = false
        #expect(pipeline.status == .demo)
    }

    @Test func sleepLeavesStoppedPipelineStopped() {
        let pipeline = AudioPipeline(store: FrameStore(), processes: AudioProcessList(), output: OutputDeviceMonitor())
        pipeline.stopForSleep()
        pipeline.restartAfterSleep()
        #expect(pipeline.status == .stopped)
        #expect(pipeline.ringForTesting.activeWriters == 0)
    }

    @Test func modelSleepStopsDemoAndWakeRestoresIt() async throws {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.sleep-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = try Self.makeShortDemo()
        defer { try? FileManager.default.removeItem(at: file) }

        let model = AppModel(defaults: defaults)
        model.start(arguments: LaunchArguments(demoFile: file, noCapture: true))
        defer { model.stop() }
        #expect(model.pipeline.status == .demo)

        model.systemWillSleep()
        #expect(model.pipeline.status == .stopped)
        #expect(model.pipeline.ringForTesting.activeWriters == 0)

        model.systemDidWake()
        // Запуск через `wakeDelay` (1 с), до этого источник стоит.
        #expect(model.pipeline.status == .stopped)
        let wake = try #require(model.pendingWakeForTesting)
        await wake.value
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

    /// Короткий файл (0,5 с синуса) вместо 20-секундного `demo.wav`: чтение файла идет на
    /// главном акторе, а циклов много.
    private static func makeShortDemo() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-lifecycle-\(UUID().uuidString).caf")
        let sampleRate = 48_000.0
        let frames = AVAudioFrameCount(sampleRate / 2)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        }
        // Файл закрывается, когда `AVAudioFile` освобождается в конце этой области.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }
}
