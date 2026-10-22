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
