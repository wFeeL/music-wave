import Foundation
import Testing
@testable import WaveCore

struct LevelSpringTests {
    /// Время, когда значение впервые переходит через `threshold` при шаге `dt`.
    private func crossing(from start: Float, toward target: Float, threshold: Float, dt: Double) -> Double? {
        var spring = LevelSpring()
        spring.reset(to: start)
        for frame in 1...Int(1 / dt) {
            let value = spring.step(toward: target, dt: dt)
            let crossed = target > start ? value >= threshold : value <= threshold
            if crossed { return Double(frame) * dt }
        }
        return nil
    }

    @Test func riseReachesHalfIn37ms() {
        let time = crossing(from: 0, toward: 1, threshold: 0.5, dt: 1.0 / 240)
        #expect(time.map { $0 >= 0.035 && $0 <= 0.040 } == true, "\(String(describing: time))")
    }

    @Test func fallReachesHalfIn140ms() {
        let time = crossing(from: 1, toward: 0, threshold: 0.5, dt: 1.0 / 240)
        #expect(time.map { $0 >= 0.13 && $0 <= 0.15 } == true, "\(String(describing: time))")
    }

    @Test func neverOvershoots() {
        for fps in [60.0, 120.0] {
            for (start, target) in [(Float(0), Float(1)), (1, 0)] {
                var spring = LevelSpring()
                spring.reset(to: start)
                for _ in 0..<Int(fps) {
                    let value = spring.step(toward: target, dt: 1 / fps)
                    #expect(value >= -1e-6 && value <= 1 + 1e-6, "\(fps) Hz \(start)->\(target): \(value)")
                }
            }
        }
    }

    @Test func frameRateIndependent() {
        for (start, target) in [(Float(0), Float(1)), (1, 0)] {
            var at60 = LevelSpring(value: start)
            var at120 = LevelSpring(value: start)
            for _ in 0..<6 { at60.step(toward: target, dt: 1.0 / 60) }
            for _ in 0..<12 { at120.step(toward: target, dt: 1.0 / 120) }
            #expect(abs(at60.value - at120.value) < 1e-4, "\(at60.value) vs \(at120.value)")
        }
    }

    @Test func velocityStartsFromRest() {
        for fps in [60.0, 120.0] {
            var spring = LevelSpring()
            #expect(spring.velocity == 0)
            var fastest: Float = 0
            for _ in 0..<Int(fps) {
                spring.step(toward: 1, dt: 1 / fps)
                fastest = max(fastest, abs(spring.velocity))
            }
            #expect(fastest > 0)
            #expect(Double(fastest) <= 45 / exp(1.0) * 1.01, "\(fps) Hz: \(fastest)")
        }
    }

    @Test func ignoresInvalidInput() {
        var spring = LevelSpring(value: 0.3)
        spring.step(toward: 1, dt: 1.0 / 60)
        let value = spring.value
        let velocity = spring.velocity
        spring.step(toward: .nan, dt: 1.0 / 60)
        spring.step(toward: 1, dt: .nan)
        spring.step(toward: 1, dt: -1)
        #expect(spring.value == value && spring.velocity == velocity)
        #expect(spring.value.isFinite && spring.velocity.isFinite)
    }

    @Test func resetStopsTheSpring() {
        var spring = LevelSpring()
        spring.step(toward: 1, dt: 1.0 / 60)
        spring.reset(to: 0.5)
        #expect(spring.value == 0.5 && spring.velocity == 0)
        spring.reset()
        #expect(spring.value == 0 && spring.velocity == 0)
    }
    /// Своя частота: спектр берет рост 45 и спад 10 рад/с, половина пути вниз за 168 мс. Без
    /// параметров пружина та же, что и раньше.
    @Test func customOmegasSetTheHalfTimes() {
        func halfTime(_ spring: LevelSpring, from start: Float, toward target: Float) -> Double? {
            var spring = spring
            spring.reset(to: start)
            let dt = 1.0 / 2400
            for frame in 1...2400 {
                let value = spring.step(toward: target, dt: dt)
                if target > start ? value >= 0.5 : value <= 0.5 { return Double(frame) * dt }
            }
            return nil
        }
        let spectrum = LevelSpring(value: 0, riseOmega: 45, fallOmega: 10)
        #expect(spectrum.riseOmega == 45 && spectrum.fallOmega == 10)
        let down = halfTime(spectrum, from: 1, toward: 0)
        #expect(down.map { abs($0 - 0.168) <= 0.002 } == true, "\(String(describing: down))")
        let up = halfTime(spectrum, from: 0, toward: 1)
        #expect(up.map { abs($0 - 0.0373) <= 0.001 } == true, "\(String(describing: up))")

        let standard = LevelSpring(value: 0.2)
        #expect(standard.riseOmega == LevelSpring.riseOmega && standard.fallOmega == LevelSpring.fallOmega)
        var a = LevelSpring(value: 0.2)
        var b = LevelSpring(value: 0.2, riseOmega: LevelSpring.riseOmega, fallOmega: LevelSpring.fallOmega)
        for target in [Float(0.9), 0.1, 0.5] {
            for _ in 0..<7 {
                #expect(a.step(toward: target, dt: 1.0 / 60) == b.step(toward: target, dt: 1.0 / 60))
            }
        }
        // Не конечная или не положительная частота берет частоту по умолчанию.
        let bad = LevelSpring(value: 0, riseOmega: .nan, fallOmega: -3)
        #expect(bad.riseOmega == LevelSpring.riseOmega && bad.fallOmega == LevelSpring.fallOmega)
    }

    /// Шаг точный: один шаг 1/30 с равен двум шагам 1/60 с при той же цели.
    @Test func customSpringIsFrameRateIndependent() {
        for (start, target) in [(Float(0), Float(1)), (1, 0)] {
            var once = LevelSpring(value: start, riseOmega: 45, fallOmega: 10)
            var twice = once
            once.step(toward: target, dt: 1.0 / 30)
            twice.step(toward: target, dt: 1.0 / 60)
            twice.step(toward: target, dt: 1.0 / 60)
            #expect(abs(once.value - twice.value) < 1e-6, "\(once.value) vs \(twice.value)")
            #expect(abs(once.velocity - twice.velocity) < 1e-4)
        }
    }
}
