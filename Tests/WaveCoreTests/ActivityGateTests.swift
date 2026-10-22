import Testing
@testable import WaveCore

struct ActivityGateTests {
    /// Подает уровень каждые 50 мс от `start` до `start + duration` включительно.
    private static func feed(_ gate: inout ActivityGate, db: Float, from start: Double, duration: Double) {
        let steps = Int((duration / 0.05).rounded())
        for i in 0...steps {
            gate.update(levelDB: db, now: start + Double(i) * 0.05)
        }
    }

    @Test func gateNeedsHoldTimeToToggle() {
        var gate = ActivityGate()
        Self.feed(&gate, db: -30, from: 0, duration: 0.2)
        #expect(!gate.isActive)
        Self.feed(&gate, db: -30, from: 0.25, duration: 0.1)
        #expect(gate.isActive)

        Self.feed(&gate, db: -100, from: 0.4, duration: 0.2)
        #expect(gate.isActive)
        Self.feed(&gate, db: -100, from: 0.65, duration: 0.1)
        #expect(!gate.isActive)
    }

    @Test func shortBlipDoesNotResetHoldTimer() {
        var gate = ActivityGate()
        Self.feed(&gate, db: -30, from: 0, duration: 0.2)
        gate.update(levelDB: -100, now: 0.25)
        Self.feed(&gate, db: -30, from: 0.3, duration: 0.2)
        #expect(!gate.isActive)
        Self.feed(&gate, db: -30, from: 0.55, duration: 0.15)
        #expect(gate.isActive)
    }
}
