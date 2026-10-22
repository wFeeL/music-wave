import CoreAudio
import Foundation
import Synchronization
import Testing
import WaveCore
@testable import WaveFeels

/// Захват не восстанавливается быстрыми попытками: конвейер продолжает пробовать раз в
/// `slowRetryInterval`, а не ждет следующего события. Сроки короткие, захват поддельный.
@Suite(.serialized)
@MainActor
struct CaptureRecoveryPipelineTests {
    static let timing = CaptureRecovery.Timing(
        zeroRunLimit: 0.1,
        maxWatchdogRebuilds: 5,
        watchdogPauses: [0.01],
        startRetryPauses: [0.01, 0.01, 0.01],
        slowRetryInterval: 0.4,
        watchdogInterval: 0.02,
        audioReturnGrace: 0.3
    )
    /// Допуск снизу на интервал между медленными повторами: часы задач и `systemUptime` разные.
    static let slack = 0.9

    /// Конвейер с поддельным захватом и короткими сроками. Монитор вывода молчит о смене
    /// устройства и перезапуске coreaudiod: пересборка по ним (на раннере устройство вывода
    /// может смениться посреди теста) сбила бы интервалы между медленными повторами.
    private static func makePipeline(
        _ fake: FakeTapCapture,
        processes: AudioProcessList? = nil
    ) -> AudioPipeline {
        let output = OutputDeviceMonitor()
        let pipeline = AudioPipeline(
            store: FrameStore(),
            processes: processes ?? AudioProcessList(),
            output: output,
            timing: timing,
            makeCapture: { _ in fake }
        )
        output.onDeviceChange = nil
        output.onServiceRestart = nil
        return pipeline
    }

    @Test func failingTapIsRetriedSlowlyAfterFastRetries() async throws {
        let fake = FakeTapCapture(behavior: .failing)
        let pipeline = Self.makePipeline(fake)
        defer { pipeline.stop() }
        pipeline.start()

        // Запуск и 3 быстрых повтора, затем 3 медленных.
        #expect(await waitUntil(.seconds(30)) { fake.startTimes.count >= 7 })
        #expect(pipeline.recoveryExhausted)
        let times = fake.startTimes
        for index in 4..<7 {
            #expect(times[index] - times[index - 1] >= Self.timing.slowRetryInterval * Self.slack, "повтор \(index)")
        }
        #expect(pipeline.lastCaptureError?.message == FakeTapCapture.failure)
    }

    @Test func zeroWatchdogKeepsRebuildingSlowlyPastFiveAttempts() async throws {
        let fake = FakeTapCapture(behavior: .silent)
        let pipeline = Self.makePipeline(fake)
        defer { pipeline.stop() }
        // Весь звук системы: «звучит» решает Now Playing.
        pipeline.adapterAvailable = true
        pipeline.adapterSaysPlaying = true
        #expect(pipeline.sourceOutputting)
        pipeline.start()

        // Запуск, 5 быстрых пересборок сторожа и 3 медленных.
        #expect(await waitUntil(.seconds(60)) { fake.startTimes.count >= 9 })
        #expect(pipeline.watchdogRebuilds == Self.timing.maxWatchdogRebuilds)
        #expect(pipeline.recoveryExhausted)
        let times = fake.startTimes
        for index in 6..<9 {
            #expect(times[index] - times[index - 1] >= Self.timing.slowRetryInterval * Self.slack, "пересборка \(index)")
        }

        // Смена источника дает все быстрые попытки заново.
        pipeline.source = .application(bundleID: "com.example.none", bundlePath: "/nonexistent.app", displayName: "Нет")
        #expect(pipeline.watchdogRebuilds == 0)
        #expect(!pipeline.recoveryExhausted)
    }

    /// Источник закрылся, пока быстрые попытки исчерпаны: конвейер ждет источник, попытки
    /// сброшены, и подсказка о захвате без звука (`AppModel.captureStallHint` берется из
    /// `CaptureHints` на каждом тике) снимается.
    @Test func exhaustionClearsWhenSourceQuits() async throws {
        let fake = FakeTapCapture(behavior: .silent)
        let list = FakeProcessList([FakeProcessList.player])
        let processes = AudioProcessList()
        processes.snapshotOverride = { list.processes }
        let pipeline = Self.makePipeline(fake, processes: processes)
        defer { pipeline.stop() }
        pipeline.source = FakeProcessList.source
        pipeline.adapterAvailable = true
        pipeline.adapterSaysPlaying = true
        pipeline.start()

        #expect(await waitUntil(.seconds(30)) { pipeline.recoveryExhausted })
        #expect(CaptureHints(access: .authorized, recoveryExhausted: pipeline.recoveryExhausted).stalled)

        list.processes = []
        processes.onChange?()
        #expect(await waitUntil(.seconds(5)) { pipeline.status == .waitingForSource })
        #expect(!pipeline.recoveryExhausted)
        #expect(!CaptureHints(access: .authorized, recoveryExhausted: pipeline.recoveryExhausted).stalled)
    }

    /// В приостановке вывод звука перечитывается на смене списка и при тех же номерах
    /// процессов, а перезапуск coreaudiod ставит подписки на вывод заново.
    @Test func suspendedOutputStateRefreshesWithSameProcessIDs() async throws {
        let fake = FakeTapCapture(behavior: .silent)
        let list = FakeProcessList([FakeProcessList.player])
        let processes = AudioProcessList()
        processes.snapshotOverride = { list.processes }
        processes.runningOutputOverride = { _ in list.outputting }
        let output = OutputDeviceMonitor()
        let pipeline = AudioPipeline(
            store: FrameStore(),
            processes: processes,
            output: output,
            makeCapture: { _ in fake }
        )
        defer { pipeline.stop() }
        pipeline.source = FakeProcessList.source
        pipeline.start()
        let running = PipelineStatus.capturing(.running(sampleRate: FakeTapCapture.sampleRate, processCount: 1))
        #expect(await waitUntil(.seconds(10)) { pipeline.status == running })

        // Процесс выводил звук и при входе в приостановку: он ее не прерывает.
        pipeline.suspendIdle()
        #expect(pipeline.status == .suspended)
        #expect(pipeline.sourceProcessOutputting())
        let subscriptions = pipeline.outputWatchSubscriptionsForTesting

        // Вывод кончился, список сменился с теми же номерами.
        list.outputting = false
        processes.onChange?()
        #expect(!pipeline.sourceProcessOutputting())
        #expect(pipeline.outputWatchSubscriptionsForTesting == subscriptions)

        // coreaudiod перезапущен, номера те же: подписки ставятся заново.
        output.onServiceRestart?()
        #expect(pipeline.outputWatchSubscriptionsForTesting == subscriptions + 1)
        #expect(pipeline.status == .suspended)
    }
}

/// Список процессов для `AudioProcessList.snapshotOverride`: тест меняет его и сам вызывает
/// `onChange`.
@MainActor
final class FakeProcessList {
    static let source = AudioSource.application(
        bundleID: "com.example.player",
        bundlePath: "/nonexistent/Player.app",
        displayName: "Плеер"
    )
    static let player = AudioProcessInfo(
        objectID: 7001,
        pid: 7001,
        bundleID: "com.example.player",
        executablePath: nil,
        isRunningOutput: true
    )

    var processes: [AudioProcessInfo]
    /// Ответ `AudioProcessList.runningOutputOverride` для любого процесса.
    var outputting = true

    init(_ processes: [AudioProcessInfo]) {
        self.processes = processes
    }
}

/// Захват без Core Audio: tap либо никогда не создается, либо создается и молчит (в кольцо
/// ничего не пишется, анализ видит нули). Запуски идут на своей очереди, как у настоящего.
final class FakeTapCapture: TapCapturing {
    enum Behavior: Sendable {
        case failing
        case silent
    }

    static let failure = "поддельный tap не создан"
    static let sampleRate = 48_000.0

    private struct State: Sendable {
        var status: TapStatus = .idle
        var startTimes: [Double] = []
    }

    private let behavior: Behavior
    private let queue = DispatchQueue(label: "com.wfeels.wavefeels.tests.fake-tap")
    private let state = Mutex(State())

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    /// Когда вызывался `start`, по `systemUptime`.
    var startTimes: [Double] { state.withLock { $0.startTimes } }

    var status: TapStatus { state.withLock { $0.status } }

    var sampleRate: Double {
        if case .running(let rate, _) = status { return rate }
        return 0
    }

    func start(
        processObjectIDs: [AudioObjectID],
        systemWide: Bool,
        outputDeviceUID: String,
        completion: @escaping @Sendable (Result<Double, TapError>, String?) -> Void
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let behavior = self.behavior
        queue.async {
            switch behavior {
            case .failing:
                self.state.withLock {
                    $0.startTimes.append(now)
                    $0.status = .failed(Self.failure)
                }
                completion(.failure(TapError(message: Self.failure)), nil)
            case .silent:
                self.state.withLock {
                    $0.startTimes.append(now)
                    $0.status = .running(sampleRate: Self.sampleRate, processCount: processObjectIDs.count)
                }
                completion(.success(Self.sampleRate), nil)
            }
        }
    }

    @discardableResult
    func stop() -> String? {
        queue.sync {
            state.withLock { $0.status = .idle }
        }
        return nil
    }

    func stopInBackground(completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            self.state.withLock { $0.status = .idle }
            completion(nil)
        }
    }

    func waitUntilIdle(timeout: Double) -> Bool {
        queue.sync {}
        return true
    }
}

/// Ждет условия, отпуская главный актор между проверками.
@MainActor
private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
