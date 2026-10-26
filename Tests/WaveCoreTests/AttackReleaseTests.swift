import Testing
@testable import WaveCore

@Suite struct AttackReleaseTests {
    @Test func attackReachesTimeConstantFraction() {
        var smoother = AttackRelease()
        let value = smoother.step(toward: 1, dt: 0.03)
        #expect(abs(value - 0.632) < 0.01)
        #expect(smoother.value == value)
    }

    @Test func releaseDecaysToOneOverE() {
        var smoother = AttackRelease()
        smoother.reset(to: 1)
        var value: Float = 1
        for _ in 0..<15 {
            value = smoother.step(toward: 0, dt: 1.0 / 60.0)
        }
        #expect(abs(value - 0.368) < 0.01)
    }

    @Test func zeroDtKeepsValue() {
        var smoother = AttackRelease()
        smoother.reset(to: 0.4)
        #expect(smoother.step(toward: 1, dt: 0) == 0.4)
        #expect(smoother.step(toward: 0, dt: 0) == 0.4)
    }

    @Test func resetSetsValue() {
        var smoother = AttackRelease()
        smoother.reset(to: 0.7)
        #expect(smoother.value == 0.7)
        smoother.reset()
        #expect(smoother.value == 0)
    }
}

@Suite struct GravityReleaseTests {
    /// Пик 1, затем цель 0 шагами `dt`; значение после шага, ближайшего ко времени `time`.
    private func fall(dt: Double, target: Float = 0, at time: Double) -> Float {
        var gravity = GravityRelease()
        gravity.reset(to: 1)
        var value: Float = 1
        for _ in 0..<Int((time / dt).rounded()) {
            value = gravity.step(toward: target, dt: dt)
        }
        return value
    }

    @Test func gravityHoldsThenFallsToZeroInAboutThirdSecond() {
        #expect(fall(dt: 1.0 / 200, at: 0.03) == 1)
        #expect(abs(fall(dt: 1.0 / 200, at: 0.19) - 0.75) < 0.02)
        #expect(fall(dt: 1.0 / 200, at: 0.35) == 0)
    }

    @Test func gravityStopsAtTarget() {
        var gravity = GravityRelease()
        gravity.reset(to: 1)
        var lowest: Float = 1
        for _ in 0..<200 {
            lowest = min(lowest, gravity.step(toward: 0.6, dt: 1.0 / 200))
        }
        #expect(lowest == 0.6)
        #expect(gravity.value == 0.6)
    }

    @Test func gravityIsFrameRateIndependent() {
        let fine = fall(dt: 1.0 / 200, at: 0.2)
        let coarse = fall(dt: 1.0 / 15, at: 0.2)
        #expect(abs(fine - coarse) < 1e-3)
    }

    @Test func newPeakRestartsHold() {
        var gravity = GravityRelease()
        gravity.reset(to: 1)
        for _ in 0..<(200 * 3 / 10) {
            gravity.step(toward: 0, dt: 1.0 / 200)
        }
        let falling = gravity.value
        #expect(falling < 0.5)
        // Новая цель выше текущего значения: рост, затем снова удержание на новом пике.
        var peak = falling
        for _ in 0..<40 {
            peak = gravity.step(toward: 0.8, dt: 1.0 / 200)
        }
        #expect(peak > falling)
        let top = peak
        for _ in 0..<7 {
            gravity.step(toward: 0, dt: 1.0 / 200)
        }
        #expect(gravity.value == top)
    }

    @Test func zeroDtKeepsValueAndResetSetsIt() {
        var gravity = GravityRelease()
        gravity.reset(to: 0.4)
        #expect(gravity.step(toward: 1, dt: 0) == 0.4)
        #expect(gravity.step(toward: 0, dt: 0) == 0.4)
        gravity.reset()
        #expect(gravity.value == 0)
    }
    /// Своя выдержка и спад: призрак пика спектра держится 120 мс и падает с пика до нуля за
    /// 0.6 с. Нулевая атака ставит цель сразу и ровно. Без параметров все как раньше.
    @Test func customHoldAndFall() {
        var ghost = GravityRelease(attack: 0, hold: 0.12, fall: 0.6)
        #expect(ghost.hold == 0.12 && ghost.fall == 0.6)
        #expect(ghost.step(toward: 0.3, dt: 1.0 / 60) == 0.3)
        #expect(ghost.step(toward: 0.7000001, dt: 1.0 / 60) == 0.7000001)
        func value(at time: Double) -> Float {
            var gravity = GravityRelease(attack: 0, hold: 0.12, fall: 0.6)
            gravity.reset(to: 1)
            var value: Float = 1
            for _ in 0..<Int((time * 200).rounded()) {
                value = gravity.step(toward: 0, dt: 1.0 / 200)
            }
            return value
        }
        #expect(value(at: 0.11) == 1)
        // Половина спада: 1 − 0.5² = 0.75.
        #expect(abs(value(at: 0.42) - 0.75) < 0.01)
        #expect(value(at: 0.73) == 0)

        let standard = GravityRelease()
        #expect(standard.hold == GravityRelease.hold && standard.fall == GravityRelease.fall)
        // Не конечные и отрицательные значения берут значения по умолчанию.
        let bad = GravityRelease(attack: 0, hold: -1, fall: .nan)
        #expect(bad.hold == GravityRelease.hold && bad.fall == GravityRelease.fall)
    }
}
