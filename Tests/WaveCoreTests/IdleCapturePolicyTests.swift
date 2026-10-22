import Testing
@testable import WaveCore

struct IdleCapturePolicyTests {
    /// Тишина: уровень ниже порога, Now Playing не играет.
    private static func silence(
        nowPlaying: Bool,
        suspended: Bool = false,
        adapterAvailable: Bool = true
    ) -> IdleCapturePolicy.Inputs {
        IdleCapturePolicy.Inputs(
            audioActive: false,
            sourcePlaying: false,
            adapterAvailable: adapterAvailable,
            sourceReportsNowPlaying: nowPlaying,
            suspended: suspended
        )
    }

    /// Первое действие, кроме `.none`, и его момент.
    private struct Event: Equatable {
        var action: IdleCapturePolicy.Action
        var at: Double
    }

    /// Подает одни и те же входы каждые 100 мс от `start` до `end` включительно и возвращает
    /// первое действие, кроме `.none`.
    private static func run(
        _ policy: inout IdleCapturePolicy,
        _ inputs: IdleCapturePolicy.Inputs,
        from start: Double,
        to end: Double
    ) -> Event? {
        let steps = Int(((end - start) / 0.1).rounded())
        for i in 0...steps {
            let now = start + Double(i) * 0.1
            let action = policy.update(inputs, now: now)
            if action != .none { return Event(action: action, at: now) }
        }
        return nil
    }

    /// Telegram, игры, весь звук без плеера: Now Playing об источнике молчит, tap остается
    /// единственным, кто узнает о начале звука, поэтому захват не останавливается.
    @Test func sourceWithoutNowPlayingIsNeverSuspended() {
        var policy = IdleCapturePolicy()
        let event = Self.run(&policy, Self.silence(nowPlaying: false), from: 0, to: 60)
        #expect(event == nil)
    }

    /// Адаптер не работает: тоже не останавливать.
    @Test func unavailableAdapterIsNeverSuspended() {
        var policy = IdleCapturePolicy()
        let event = Self.run(&policy, Self.silence(nowPlaying: true, adapterAvailable: false), from: 0, to: 60)
        #expect(event == nil)
    }

    @Test func sourceWithNowPlayingIsSuspendedAfterTenSeconds() throws {
        var policy = IdleCapturePolicy()
        let event = try #require(Self.run(&policy, Self.silence(nowPlaying: true), from: 0, to: 20))
        #expect(event.action == .suspend)
        #expect(abs(event.at - IdleCapturePolicy.defaultDelay) < 0.05)
    }

    @Test func soundResetsSilenceTimer() throws {
        var policy = IdleCapturePolicy()
        let early = Self.run(&policy, Self.silence(nowPlaying: true), from: 0, to: 9)
        #expect(early == nil)
        var loud = Self.silence(nowPlaying: true)
        loud.audioActive = true
        let onSound = policy.update(loud, now: 9.1)
        #expect(onSound == .none)
        let event = try #require(Self.run(&policy, Self.silence(nowPlaying: true), from: 9.2, to: 30))
        #expect(event.action == .suspend)
        #expect(abs(event.at - 19.2) < 0.05)
    }

    @Test func suspendedCaptureResumesOnSoundOrPlayback() {
        var policy = IdleCapturePolicy()
        var quiet = Self.silence(nowPlaying: true, suspended: true)
        var playing = quiet
        playing.sourcePlaying = true
        var loud = quiet
        loud.audioActive = true
        let actions = [
            policy.update(quiet, now: 0),
            policy.update(playing, now: 0.1),
            policy.update(loud, now: 0.2),
        ]
        #expect(actions == [.none, .resume, .resume])
        quiet.suspended = false
        let afterResume = policy.update(quiet, now: 0.3)
        #expect(afterResume == .none)
    }

    /// Источник сменился (Now Playing о новом еще ничего не сообщал) или адаптер перестал
    /// работать: приостановка больше не оправдана.
    @Test func suspendedCaptureResumesWhenNowPlayingCanNoLongerTell() {
        var policy = IdleCapturePolicy()
        let actions = [
            policy.update(Self.silence(nowPlaying: true, suspended: true), now: 0),
            policy.update(Self.silence(nowPlaying: false, suspended: true), now: 0.1),
            policy.update(Self.silence(nowPlaying: true, suspended: true, adapterAvailable: false), now: 0.2),
        ]
        #expect(actions == [.none, .resume, .resume])
    }

    /// Захват возобновился без политики (процесс начал выводить звук): тишина считается заново,
    /// а не с момента до приостановки.
    @Test func silenceIsCountedAnewAfterResume() throws {
        var policy = IdleCapturePolicy()
        let first = try #require(Self.run(&policy, Self.silence(nowPlaying: true), from: 0, to: 20))
        #expect(first == Event(action: .suspend, at: first.at))
        let whileSuspended = Self.run(&policy, Self.silence(nowPlaying: true, suspended: true), from: 10.1, to: 30)
        #expect(whileSuspended == nil)
        let second = try #require(Self.run(&policy, Self.silence(nowPlaying: true), from: 30.1, to: 60))
        #expect(second.action == .suspend)
        #expect(abs(second.at - 40.1) < 0.05)
    }
}

struct OutputStartDetectorTests {
    /// Процесс, который уже выводил звук при приостановке, не будит; новый или снова начавший будит.
    @Test func wakesOnlyWhenAProcessStartsOutput() {
        var detector = OutputStartDetector(outputting: [5])
        let checks: [Set<UInt32>] = [[5], [], [5], [5], [5, 9], [9]]
        let wakes = checks.map { detector.update(outputting: $0) }
        #expect(wakes == [false, false, true, false, true, false])
    }

    @Test func emptyBaselineWakesOnFirstOutput() {
        var detector = OutputStartDetector(outputting: [])
        let wakes = [[], [42]].map { detector.update(outputting: Set<UInt32>($0)) }
        #expect(wakes == [false, true])
    }
}
