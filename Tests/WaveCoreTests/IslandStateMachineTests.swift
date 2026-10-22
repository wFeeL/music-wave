import Testing
@testable import WaveCore

@Suite struct IslandStateMachineTests {
    private static let step = 0.1

    /// Подает одни и те же входы с шагом 0.1 с на отрезке [from, to] и возвращает последнее состояние.
    @discardableResult
    private func run(
        _ machine: inout IslandStateMachine, _ inputs: IslandInputs, from: Double, to: Double
    ) -> IslandState {
        let count = Int(((to - from) / Self.step).rounded())
        var result = machine.state
        for i in 0...count {
            result = machine.update(inputs, now: from + Double(i) * Self.step)
        }
        return result
    }

    private let playing = IslandInputs(audioActive: true)
    private let silent = IslandInputs()

    @Test func showsWhenAudioStarts() {
        var machine = IslandStateMachine()
        #expect(machine.update(silent, now: 0) == .hidden)
        #expect(machine.update(playing, now: 0.1) == .collapsed)
    }

    @Test func hidesAfterHideDelayOfSilence() {
        var machine = IslandStateMachine()
        machine.update(playing, now: 0)
        #expect(run(&machine, silent, from: 1, to: 4.9 + 1) == .collapsed)
        #expect(machine.update(silent, now: 6.1) == .hidden)
    }

    @Test func briefHoverDoesNotExpand() {
        var machine = IslandStateMachine()
        machine.update(playing, now: 0)
        var hover = playing
        hover.pointerInHoverZone = true
        #expect(run(&machine, hover, from: 1, to: 1.1) == .collapsed)
        #expect(machine.update(playing, now: 1.2) == .collapsed)
    }

    @Test func hoverExpandsAfterDelay() {
        var machine = IslandStateMachine()
        machine.update(playing, now: 0)
        var hover = playing
        hover.pointerInHoverZone = true
        #expect(run(&machine, hover, from: 1, to: 1.2) == .expanded)
    }

    @Test func expandsOnPauseWithLastTrack() {
        var machine = IslandStateMachine()
        let paused = IslandInputs(sourceRunning: true, hasLastTrack: true, pointerInHoverZone: true)
        #expect(run(&machine, paused, from: 0, to: 0.2) == .expanded)
    }

    @Test func doesNotExpandWithoutAnything() {
        var machine = IslandStateMachine()
        let hover = IslandInputs(pointerInHoverZone: true)
        #expect(run(&machine, hover, from: 0, to: 2) == .hidden)
        let noTrack = IslandInputs(sourceRunning: true, pointerInHoverZone: true)
        #expect(run(&machine, noTrack, from: 2.1, to: 4) == .hidden)
    }

    @Test func collapsesAfterPointerLeaves() {
        var machine = IslandStateMachine()
        var hover = playing
        hover.pointerInHoverZone = true
        #expect(run(&machine, hover, from: 0, to: 1) == .expanded)
        #expect(run(&machine, playing, from: 1.1, to: 1.3) == .expanded)
        #expect(machine.update(playing, now: 1.45) == .collapsed)
    }

    @Test func collapsesToHiddenWhenNoContent() {
        var machine = IslandStateMachine()
        let hover = IslandInputs(sourceRunning: true, hasLastTrack: true, pointerInHoverZone: true)
        #expect(run(&machine, hover, from: 0, to: 20) == .expanded)
        #expect(run(&machine, silent, from: 20.1, to: 20.3) == .expanded)
        #expect(machine.update(silent, now: 20.45) == .hidden)
    }

    @Test func fullscreenHidesImmediately() {
        var machine = IslandStateMachine()
        machine.update(playing, now: 0)
        var suppressed = playing
        suppressed.fullscreenSuppressed = true
        #expect(machine.update(suppressed, now: 0.1) == .hidden)
        #expect(machine.update(playing, now: 0.2) == .collapsed)
    }

    @Test func userPauseHidesImmediately() {
        var machine = IslandStateMachine()
        machine.update(playing, now: 0)
        var paused = playing
        paused.userPaused = true
        #expect(machine.update(paused, now: 0.1) == .hidden)
        paused.pointerInHoverZone = true
        #expect(run(&machine, paused, from: 0.2, to: 2) == .hidden)
    }

    @Test func parkedPointerCountsOnlyOnceIslandCanExpand() {
        var machine = IslandStateMachine()
        let parked = IslandInputs(pointerInHoverZone: true)
        #expect(run(&machine, parked, from: 0, to: 2) == .hidden)
        #expect(machine.pointerDeadline == nil)
        // Музыка началась под стоящим в вырезе курсором: сначала свернутый остров, раскрытие
        // только через `expandDelay`.
        var playingParked = playing
        playingParked.pointerInHoverZone = true
        #expect(machine.update(playingParked, now: 2.1) == .collapsed)
        #expect(machine.update(playingParked, now: 2.2) == .collapsed)
        #expect(machine.update(playingParked, now: 2.25) == .expanded)
    }

    @Test func pointerDeadlineTracksExpandAndCollapse() throws {
        var machine = IslandStateMachine()
        machine.update(playing, now: 0)
        #expect(machine.pointerDeadline == nil)
        var hover = playing
        hover.pointerInHoverZone = true
        machine.update(hover, now: 1)
        let expandAt = try #require(machine.pointerDeadline)
        #expect(abs(expandAt - 1.15) < 1e-9)
        #expect(machine.update(hover, now: expandAt) == .expanded)
        #expect(machine.pointerDeadline == nil)

        machine.update(playing, now: 2)
        let collapseAt = try #require(machine.pointerDeadline)
        #expect(abs(collapseAt - 2.3) < 1e-9)
        #expect(machine.update(playing, now: collapseAt) == .collapsed)
        #expect(machine.pointerDeadline == nil)
    }

    @Test func silenceTimerResetsWhenMusicResumes() {
        var machine = IslandStateMachine()
        machine.update(playing, now: 0)
        #expect(run(&machine, silent, from: 1, to: 4) == .collapsed)
        machine.update(playing, now: 4.1)
        #expect(run(&machine, silent, from: 4.2, to: 7.2) == .collapsed)
    }

    @Test func transitionKeepsBothWaveLayers() {
        func layers(_ state: IslandState, _ since: Double) -> (wing: Bool, panel: Bool) {
            IslandTransition.waveLayers(state: state, sinceStateChange: since)
        }
        let collapsed = layers(.collapsed, 5)
        #expect(collapsed.wing == true)
        #expect(collapsed.panel == false)
        let expanding = layers(.expanded, 0.3)
        #expect(expanding.wing == true)
        #expect(expanding.panel == true)
        let expanded = layers(.expanded, 0.81)
        #expect(expanded.wing == false)
        #expect(expanded.panel == true)
        let collapsing = layers(.collapsed, 0.5)
        #expect(collapsing.wing == true)
        #expect(collapsing.panel == true)
        let hidden = layers(.hidden, 1)
        #expect(hidden.wing == false)
        #expect(hidden.panel == false)
        // Снимки ставят смену состояния в минус бесконечность: остров давно в своем состоянии.
        let steady = layers(.expanded, .infinity)
        #expect(steady.wing == false)
        #expect(steady.panel == true)
    }

    /// «Уменьшение движения»: входящее тело проявляется первым, уходящее гаснет следом; вне
    /// свернутого острова тело меняется сразу.
    @Test func reducedMotionBodiesNeverFadeTogether() {
        #expect(IslandTransition.reducedBodyFade(incoming: true, collapsed: true) == .fadeIn)
        #expect(IslandTransition.reducedBodyFade(incoming: false, collapsed: true) == .fadeOutDelayed)
        #expect(IslandTransition.reducedBodyFade(incoming: true, collapsed: false) == .immediate)
        #expect(IslandTransition.reducedBodyFade(incoming: false, collapsed: false) == .immediate)
    }
}
