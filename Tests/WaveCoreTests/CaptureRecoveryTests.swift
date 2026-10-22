import Testing
@testable import WaveCore

struct CaptureRecoveryTests {
    private let timing = CaptureRecovery.Timing.standard

    /// Нули при звучащем источнике, пересборка давно: что решит сторож.
    private func stalled(_ recovery: inout CaptureRecovery, sinceRebuild: Double = 10) -> CaptureRecovery.WatchdogAction {
        recovery.watchdog(zeroRun: 3, sourceOutputting: true, sinceRebuild: sinceRebuild, rebuildPending: false)
    }

    @Test func standardTimingMatchesSpec() {
        #expect(timing.zeroRunLimit == 2.5)
        #expect(timing.maxWatchdogRebuilds == 5)
        #expect(timing.watchdogPauses == [1, 2, 4])
        #expect(timing.startRetryPauses == [1, 2, 4])
        #expect(timing.slowRetryInterval == 30)
    }

    @Test func watchdogRebuildsFastFiveTimesThenSlowly() {
        var recovery = CaptureRecovery()
        var pauses: [Double] = []
        for attempt in 1...5 {
            guard case .rebuild(let number, let pause) = stalled(&recovery) else {
                Issue.record("попытка \(attempt) не быстрая")
                return
            }
            #expect(number == attempt)
            pauses.append(pause)
        }
        #expect(pauses == [1, 2, 4, 4, 4])
        #expect(recovery.watchdogRebuilds == 5)
        #expect(recovery.exhausted)

        // Медленный повтор не чаще раза в `slowRetryInterval` после прошлой пересборки.
        #expect(stalled(&recovery, sinceRebuild: 29) == .none)
        #expect(stalled(&recovery, sinceRebuild: 30) == .slowRetry)
        #expect(stalled(&recovery, sinceRebuild: 45) == .slowRetry)
        #expect(recovery.watchdogRebuilds == 5)
        #expect(recovery.exhausted)
    }

    @Test func watchdogWaitsForSoundingSourceLongZerosAndNoPendingRebuild() {
        var recovery = CaptureRecovery()
        #expect(recovery.watchdog(zeroRun: 3, sourceOutputting: false, sinceRebuild: 10, rebuildPending: false) == .none)
        #expect(recovery.watchdog(zeroRun: 2, sourceOutputting: true, sinceRebuild: 10, rebuildPending: false) == .none)
        #expect(recovery.watchdog(zeroRun: 3, sourceOutputting: true, sinceRebuild: 10, rebuildPending: true) == .none)
        #expect(recovery.watchdogRebuilds == 0)
    }

    @Test func onlyReturningSoundResetsWatchdog() {
        var recovery = CaptureRecovery()
        for _ in 1...5 { _ = stalled(&recovery) }
        #expect(recovery.exhausted)
        // Сразу после пересборки нулей еще нет: это не вернувшийся звук.
        _ = recovery.watchdog(zeroRun: 0, sourceOutputting: true, sinceRebuild: 0.5, rebuildPending: false)
        #expect(recovery.exhausted)
        // Тишина источника счетчик не трогает.
        _ = recovery.watchdog(zeroRun: 3, sourceOutputting: false, sinceRebuild: 40, rebuildPending: false)
        #expect(recovery.exhausted)
        _ = recovery.watchdog(zeroRun: 0, sourceOutputting: true, sinceRebuild: 2, rebuildPending: false)
        #expect(recovery.watchdogRebuilds == 0)
        #expect(!recovery.exhausted)
    }

    @Test func failedStartRetriesFastThenSlowly() {
        var recovery = CaptureRecovery()
        #expect(recovery.startFailed(attempt: 0) == .retry(attempt: 1, pause: 1))
        #expect(recovery.startFailed(attempt: 1) == .retry(attempt: 2, pause: 2))
        #expect(recovery.startFailed(attempt: 2) == .retry(attempt: 3, pause: 4))
        #expect(!recovery.exhausted)
        #expect(recovery.startFailed(attempt: 3) == .slowRetry(pause: 30))
        #expect(recovery.exhausted)
        // Медленный повтор идет с номером последней быстрой попытки: неудача снова медленная.
        #expect(recovery.slowRetryAttempt == 3)
        #expect(recovery.startFailed(attempt: recovery.slowRetryAttempt) == .slowRetry(pause: 30))

        recovery.startSucceeded()
        #expect(!recovery.exhausted)
    }

    @Test func resetClearsEverything() {
        var recovery = CaptureRecovery()
        for _ in 1...5 { _ = stalled(&recovery) }
        _ = recovery.startFailed(attempt: 3)
        recovery.reset()
        #expect(recovery.watchdogRebuilds == 0)
        #expect(!recovery.exhausted)
    }

    @Test func hintsSeparateDeniedAccessFromStalledCapture() {
        #expect(CaptureHints(access: .denied, recoveryExhausted: false) == CaptureHints(permission: true, stalled: false))
        #expect(CaptureHints(access: .denied, recoveryExhausted: true) == CaptureHints(permission: true, stalled: false))
        #expect(CaptureHints(access: .unknown, recoveryExhausted: false) == CaptureHints(permission: false, stalled: false))
        #expect(CaptureHints(access: .unknown, recoveryExhausted: true) == CaptureHints(permission: true, stalled: false))
        #expect(CaptureHints(access: .authorized, recoveryExhausted: false) == CaptureHints(permission: false, stalled: false))
        #expect(CaptureHints(access: .authorized, recoveryExhausted: true) == CaptureHints(permission: false, stalled: true))
    }
}
