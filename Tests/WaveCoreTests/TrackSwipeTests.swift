import Testing
@testable import WaveCore

@Suite struct TrackSwipeTests {
    /// Подает жест: `began` в `start`, затем `changed` с шагом 0.01 с по `deltas`. Возвращает
    /// команды по событиям, начиная с `began`.
    private func gesture(
        _ detector: inout TrackSwipeDetector, start: Double, deltas: [Double], dy: Double = 0
    ) -> [TrackSwipeDetector.Command?] {
        var result: [TrackSwipeDetector.Command?] = [
            detector.feed(fingerDX: 0, dy: 0, phase: .began, time: start),
        ]
        for (index, dx) in deltas.enumerated() {
            result.append(detector.feed(fingerDX: dx, dy: dy, phase: .changed, time: start + Double(index + 1) * 0.01))
        }
        return result
    }

    @Test func swipeLeftIsNext() {
        var detector = TrackSwipeDetector()
        let commands = gesture(&detector, start: 0, deltas: [-30, -40])
        #expect(commands == [nil, nil, .next])
    }

    @Test func swipeRightIsPrevious() {
        var detector = TrackSwipeDetector()
        let commands = gesture(&detector, start: 0, deltas: [30, 40])
        #expect(commands == [nil, nil, .previous])
    }

    /// Длинный свайп дает одну команду; новый жест срабатывает только после `cooldown`.
    @Test func onePerGesture() {
        var detector = TrackSwipeDetector()
        #expect(gesture(&detector, start: 0, deltas: [-30, -40]).last == .next)
        #expect(detector.feed(fingerDX: -200, dy: 0, phase: .changed, time: 0.03) == nil)
        #expect(detector.feed(fingerDX: 200, dy: 0, phase: .changed, time: 0.04) == nil)
        #expect(detector.feed(fingerDX: 0, dy: 0, phase: .ended, time: 0.05) == nil)

        let early = gesture(&detector, start: 0.1, deltas: [-100, -100])
        #expect(early.allSatisfy { $0 == nil })
        #expect(detector.feed(fingerDX: 0, dy: 0, phase: .ended, time: 0.2) == nil)

        let late = gesture(&detector, start: 0.02 + TrackSwipeDetector.cooldown, deltas: [-30, -40])
        #expect(late.last == .next)
    }

    @Test func verticalScrollIgnored() {
        var detector = TrackSwipeDetector()
        #expect(detector.feed(fingerDX: 0, dy: 0, phase: .began, time: 0) == nil)
        #expect(detector.feed(fingerDX: -70, dy: 50, phase: .changed, time: 0.01) == nil)
        #expect(detector.feed(fingerDX: 0, dy: 0, phase: .ended, time: 0.02) == nil)
    }

    /// Инерция после жеста команд не дает, даже если она длинная.
    @Test func momentumIgnored() {
        var detector = TrackSwipeDetector()
        #expect(detector.feed(fingerDX: -300, dy: 0, phase: .momentum, time: 0) == nil)
        #expect(detector.feed(fingerDX: -300, dy: 0, phase: .momentum, time: 1) == nil)
        // Инерция после короткого жеста не дотягивает его до порога.
        #expect(gesture(&detector, start: 2, deltas: [-30]).allSatisfy { $0 == nil })
        #expect(detector.feed(fingerDX: 0, dy: 0, phase: .ended, time: 2.1) == nil)
        #expect(detector.feed(fingerDX: -300, dy: 0, phase: .momentum, time: 2.2) == nil)
    }

    /// Колесо мыши шлет события без фазы: они не свайп.
    @Test func wheelWithoutPhaseIgnored() {
        var detector = TrackSwipeDetector()
        for step in 0..<10 {
            #expect(detector.feed(fingerDX: -100, dy: 0, phase: .none, time: Double(step) * 0.05) == nil)
        }
    }

    @Test func smallMoveIgnored() {
        var detector = TrackSwipeDetector()
        let commands = gesture(&detector, start: 0, deltas: [-20, -20, -10])
        #expect(commands.allSatisfy { $0 == nil })
        #expect(detector.feed(fingerDX: 0, dy: 0, phase: .ended, time: 0.1) == nil)
    }

    /// Нечисловые сдвиги и время пропускаются и не портят накопленный путь.
    @Test func nonFiniteInputIgnored() {
        var detector = TrackSwipeDetector()
        #expect(detector.feed(fingerDX: 0, dy: 0, phase: .began, time: 0) == nil)
        #expect(detector.feed(fingerDX: -.infinity, dy: 0, phase: .changed, time: 0.01) == nil)
        #expect(detector.feed(fingerDX: -30, dy: .nan, phase: .changed, time: 0.02) == nil)
        #expect(detector.feed(fingerDX: -30, dy: 0, phase: .changed, time: .nan) == nil)
        #expect(detector.feed(fingerDX: -30, dy: 0, phase: .changed, time: 0.03) == nil)
        #expect(detector.feed(fingerDX: -30, dy: 0, phase: .changed, time: 0.04) == .next)
    }

    /// Остров сменил состояние посреди жеста: жест отменен, его остаток (и потерянный `ended`)
    /// команд не дает, следующий жест с `began` работает как обычно.
    @Test func cancelledGestureWaitsForNextBegin() {
        var detector = TrackSwipeDetector()
        #expect(gesture(&detector, start: 0, deltas: [-30]).allSatisfy { $0 == nil })
        detector.cancelGesture()
        #expect(detector.feed(fingerDX: -40, dy: 0, phase: .changed, time: 0.02) == nil)
        #expect(detector.feed(fingerDX: -100, dy: 0, phase: .changed, time: 0.03) == nil)
        #expect(detector.feed(fingerDX: 0, dy: 0, phase: .ended, time: 0.04) == nil)
        #expect(gesture(&detector, start: 0.1, deltas: [-30, -40]).last == .next)
    }

    /// Отмена жеста без `ended`: события без `began` после нее молчат, сколько бы ни шли.
    @Test func cancelledGestureWithLostEndStaysSilent() {
        var detector = TrackSwipeDetector()
        #expect(gesture(&detector, start: 0, deltas: [-30]).allSatisfy { $0 == nil })
        detector.cancelGesture()
        for step in 0..<10 {
            #expect(detector.feed(fingerDX: -100, dy: 0, phase: .changed, time: 0.1 + Double(step)) == nil)
        }
        #expect(gesture(&detector, start: 20, deltas: [30, 40]).last == .previous)
    }

    /// Отмена не сбрасывает паузу после команды: смена трека, которая сама меняет остров
    /// (баннер), не дает второй команды тем же движением.
    @Test func cancelKeepsCooldown() {
        var detector = TrackSwipeDetector()
        #expect(gesture(&detector, start: 0, deltas: [-30, -40]).last == .next)
        detector.cancelGesture()
        let early = gesture(&detector, start: 0.1, deltas: [-100, -100])
        #expect(early.allSatisfy { $0 == nil })
        #expect(detector.feed(fingerDX: 0, dy: 0, phase: .ended, time: 0.2) == nil)
        #expect(gesture(&detector, start: 0.02 + TrackSwipeDetector.cooldown, deltas: [-30, -40]).last == .next)
    }
}
