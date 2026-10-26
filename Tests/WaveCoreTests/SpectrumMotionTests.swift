import Foundation
import Testing
@testable import WaveCore

/// Пружины полос «Спектра» и призрак пика над ними.
struct SpectrumMotionTests {
    private static let bandCount = BandMapper.bandCount

    private static func random(_ rng: inout SplitMix64) -> Float {
        Float(Double(rng.next() >> 11) / Double(1 << 53))
    }

    /// Пружина полосы: рост 45 рад/с, спад 10 рад/с, половина пути вниз за 168 мс.
    @Test func bandsFollowTheSpring() {
        var motion = SpectrumMotion()
        #expect(motion.values == [Float](repeating: 0, count: Self.bandCount))
        #expect(motion.peaks == motion.values)
        let dt = 1.0 / 1200
        var up: Double?
        for frame in 1...1200 {
            motion.step(bands: [Float](repeating: 1, count: Self.bandCount), dt: dt)
            if up == nil, motion.values[0] >= 0.5 { up = Double(frame) * dt }
        }
        #expect(up.map { abs($0 - 0.0373) <= 0.002 } == true, "\(String(describing: up))")
        #expect(motion.values.allSatisfy { $0 == 1 })
        var down: Double?
        for frame in 1...1200 {
            motion.step(bands: [Float](repeating: 0, count: Self.bandCount), dt: dt)
            if down == nil, motion.values[5] <= 0.5 { down = Double(frame) * dt }
        }
        #expect(down.map { abs($0 - 0.168) <= 0.003 } == true, "\(String(describing: down))")
    }

    /// Пружина не уходит выше самого большого входа и ниже нуля, призрак не ниже линии.
    @Test func noOvershootAndGhostAboveMain() {
        var rng = SplitMix64(seed: 11)
        for fps in [30.0, 60.0, 120.0] {
            var motion = SpectrumMotion()
            var highest = [Float](repeating: 0, count: Self.bandCount)
            var bands = [Float](repeating: 0, count: Self.bandCount)
            for frame in 0..<Int(20 * fps) {
                // Новая цель каждые 3 кадра: ступеньки вверх и вниз посреди движения.
                if frame % 3 == 0 {
                    bands = (0..<Self.bandCount).map { _ in Self.random(&rng) }
                }
                for band in bands.indices { highest[band] = max(highest[band], bands[band]) }
                motion.step(bands: bands, dt: 1 / fps)
                for band in 0..<Self.bandCount {
                    let value = motion.values[band]
                    #expect(value >= 0 && value <= highest[band], "\(fps) Hz frame \(frame) band \(band): \(value)")
                    #expect(motion.peaks[band] >= value, "\(fps) Hz frame \(frame) band \(band)")
                    #expect(motion.peaks[band] <= 1)
                }
            }
        }
    }

    /// Призрак сразу встает на пик, держится 120 мс и падает по параболе к линии.
    @Test func ghostHoldsThenFalls() {
        var motion = SpectrumMotion()
        let dt = 1.0 / 240
        let loud = [Float](repeating: 1, count: Self.bandCount)
        let silent = [Float](repeating: 0, count: Self.bandCount)
        for _ in 0..<240 { motion.step(bands: loud, dt: dt) }
        #expect(motion.peaks.allSatisfy { $0 == 1 })
        var time = 0.0
        while time < 0.11 {
            motion.step(bands: silent, dt: dt)
            time += dt
        }
        #expect(motion.peaks.allSatisfy { $0 == 1 }, "\(motion.peaks[0])")
        #expect(motion.values[0] < 0.7)
        while time < 0.12 + 0.3 - 1e-9 {
            motion.step(bands: silent, dt: dt)
            time += dt
        }
        // Половина спада: 1 − 0.5² = 0.75, линия к этому времени почти внизу.
        #expect(abs(motion.peaks[0] - 0.75) < 0.01, "\(motion.peaks[0])")
        #expect(motion.values[0] < 0.1)
        while time < 0.12 + 0.6 + 0.01 {
            motion.step(bands: silent, dt: dt)
            time += dt
        }
        // Призрак упал на линию и держится на ней снова, линия почти внизу.
        #expect(motion.peaks[0] >= motion.values[0] && motion.peaks[0] < 0.01, "\(motion.peaks[0])")
    }

    /// В тишине все ровно 0, и детектор простоя уходит в редкие кадры: пружины и призрак не
    /// держат полную частоту кадров. Остановка точная, а не бесконечное приближение.
    @Test func silenceConvergesToZeroAndIdles() {
        var rng = SplitMix64(seed: 3)
        var motion = SpectrumMotion()
        var detector = RenderIdleDetector()
        var now = 0.0
        let dt = 1.0 / 60
        for _ in 0..<300 {
            motion.step(bands: (0..<Self.bandCount).map { _ in Self.random(&rng) }, dt: dt)
            now += dt
            let idle = detector.update(level: motion.highest, glow: 0, pulse: 0, now: now)
            #expect(!idle)
        }
        #expect(motion.highest > 0.5)
        var idleAt: Double?
        let silenceStart = now
        for _ in 0..<(60 * 4) {
            motion.step(bands: [Float](repeating: 0, count: Self.bandCount), dt: dt)
            now += dt
            if detector.update(level: motion.highest, glow: 0, pulse: 0, now: now), idleAt == nil {
                idleAt = now - silenceStart
            }
        }
        #expect(motion.values.allSatisfy { $0 == 0 }, "\(motion.values)")
        #expect(motion.peaks.allSatisfy { $0 == 0 }, "\(motion.peaks)")
        #expect(motion.highest == 0)
        // Линия ниже порога детектора примерно через 0.7 с, призрак еще до 0.72 с (выдержка и
        // спад), затем выдержка детектора 0.5 с.
        #expect(idleAt.map { $0 <= 2 } == true, "\(String(describing: idleAt))")
    }

    /// Постоянный вход дает ровно его же: ровная линия без дрожания в младших битах.
    @Test func constantInputSettlesExactly() {
        var motion = SpectrumMotion()
        let bands = (0..<Self.bandCount).map { Float($0) / 23 * 0.8 }
        for _ in 0..<(60 * 3) { motion.step(bands: bands, dt: 1.0 / 60) }
        #expect(motion.values == bands)
        #expect(motion.peaks == bands)
    }

    /// Частота кадров не меняет движения: удары (100 мс уровня, 400 мс тишины) на 30, 60, 120 и
    /// 240 Гц. Пружина считается точно, а остановка пружины и выдержка призрака начинаются на
    /// кадре: призрак расходится не больше, чем падает за кадр более редкой частоты
    /// (`2 / peakFall` в секунду на полном пике).
    @Test func frameRateIndependent() {
        var rng = SplitMix64(seed: 5)
        var steps: [[Float]] = []
        for _ in 0..<10 {
            steps.append((0..<Self.bandCount).map { _ in Self.random(&rng) })
            steps += [[Float]](repeating: [Float](repeating: 0, count: Self.bandCount), count: 4)
        }
        func run(fps: Int) -> [SpectrumMotion] {
            var motion = SpectrumMotion()
            var frames: [SpectrumMotion] = []
            for bands in steps {
                for _ in 0..<(fps / 10) {
                    motion.step(bands: bands, dt: 1 / Double(fps))
                    frames.append(motion)
                }
            }
            return frames
        }
        for (coarse, fine) in [(30, 60), (60, 120), (120, 240)] {
            let slow = run(fps: coarse), fast = run(fps: fine)
            let ratio = fine / coarse
            let ghostBound = Float(2 / SpectrumMotion.peakFall / Double(coarse))
            var worstValue: Float = 0
            var worstPeak: Float = 0
            for (index, frame) in slow.enumerated() {
                let other = fast[ratio * index + ratio - 1]
                for band in 0..<Self.bandCount {
                    worstValue = max(worstValue, abs(frame.values[band] - other.values[band]))
                    worstPeak = max(worstPeak, abs(frame.peaks[band] - other.peaks[band]))
                }
            }
            #expect(worstValue < 0.01, "\(coarse) vs \(fine) Hz: \(worstValue)")
            #expect(worstPeak <= ghostBound, "\(coarse) vs \(fine) Hz: \(worstPeak) > \(ghostBound)")
        }
    }

    /// Плохие полосы считаются нулем, больше 1 ограничиваются, недостающие это ноль, лишние не
    /// читаются; плохой или не положительный шаг ничего не двигает. `reset` ставит значения без
    /// движения.
    @Test func badInputAndReset() {
        var motion = SpectrumMotion()
        let bad: [Float] = [.nan, .infinity, -.infinity, -1, 2, 0.4]
        for _ in 0..<120 { motion.step(bands: bad + [Float](repeating: 0, count: 18) + [1, 1], dt: 1.0 / 60) }
        #expect(motion.values.count == Self.bandCount && motion.peaks.count == Self.bandCount)
        #expect(Array(motion.values[0..<4]) == [0, 0, 0, 0])
        #expect(motion.values[4] == 1 && motion.values[5] == 0.4)
        #expect(motion.values[6...].allSatisfy { $0 == 0 })
        let before = motion
        motion.step(bands: [Float](repeating: 1, count: Self.bandCount), dt: .nan)
        motion.step(bands: [Float](repeating: 1, count: Self.bandCount), dt: 0)
        motion.step(bands: [Float](repeating: 1, count: Self.bandCount), dt: -1)
        #expect(motion.values == before.values && motion.peaks == before.peaks)

        motion.reset(to: [0.5, .nan, 3])
        #expect(Array(motion.values[0..<3]) == [0.5, 0, 1])
        #expect(motion.peaks == motion.values)
        #expect(motion.values[3...].allSatisfy { $0 == 0 })
        // После `reset(to:)` пружины стоят: тот же вход ничего не двигает.
        let set = motion.values
        motion.step(bands: set, dt: 1.0 / 60)
        #expect(motion.values == set)
        motion.reset()
        #expect(motion.values.allSatisfy { $0 == 0 } && motion.peaks.allSatisfy { $0 == 0 })
        #expect(motion.highest == 0)
    }
}
