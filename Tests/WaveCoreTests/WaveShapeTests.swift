import Foundation
import Testing
@testable import WaveCore

struct WaveShapeTests {
    private static let weights: [Double] = [1.6, 2.8, 4.4]

    @Test func waveIsZeroAtEdges() {
        for layer in WaveLayer.allCases {
            for phase in stride(from: 0.0, to: 2 * Double.pi, by: 0.37) {
                let y = WaveShape.samples(layer: layer, amplitude: 1, phase: phase, count: 128)
                #expect(y.count == 128)
                #expect(abs(y[0]) <= 1e-6)
                #expect(abs(y[127]) <= 1e-6)
                #expect(y.allSatisfy { $0.isFinite })
            }
        }
    }

    @Test func waveStaysInRange() {
        for layer in WaveLayer.allCases {
            for i in 0..<200 {
                let phase = Double(i) / 200 * 2 * Double.pi
                let y = WaveShape.samples(layer: layer, amplitude: 1, phase: phase, count: 257)
                #expect(y.allSatisfy { abs($0) <= 1 })
            }
        }
    }

    @Test func zeroAmplitudeIsFlat() {
        for layer in WaveLayer.allCases {
            let y = WaveShape.samples(layer: layer, amplitude: 0, phase: 1.3, count: 64)
            #expect(y.allSatisfy { $0 == 0 })
        }
    }

    @Test func envelopePeaksWhereSpecified() {
        let count = 401
        func argmax(_ layer: WaveLayer) -> Double {
            var peak = [Float](repeating: 0, count: count)
            for i in 0..<200 {
                let phase = Double(i) / 200 * 2 * Double.pi
                let y = WaveShape.samples(layer: layer, amplitude: 1, phase: phase, count: count)
                for j in 0..<count { peak[j] = max(peak[j], abs(y[j])) }
            }
            let best = peak.indices.max { peak[$0] < peak[$1] }!
            return Double(best) / Double(count - 1)
        }
        let bass = argmax(.bass)
        let high = argmax(.high)
        #expect(abs(bass - 0.3) < 0.15)
        #expect(abs(high - 0.7) < 0.15)
        #expect(abs(bass - 0.3) < abs(high - 0.3))
        #expect(abs(high - 0.7) < abs(bass - 0.7))
    }

    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        let twoPi = 2 * Double.pi
        let d = abs(a - b).truncatingRemainder(dividingBy: twoPi)
        return min(d, twoPi - d)
    }

    @Test func motionDependsOnLoudness() {
        var quiet = WaveMotion()
        var loud = WaveMotion()
        quiet.advance(layers: [0, 0, 0], dt: 1)
        loud.advance(layers: [1, 1, 1], dt: 1)
        for layer in WaveLayer.allCases {
            let w = Self.weights[layer.rawValue]
            #expect(circularDistance(quiet.phase(layer), (0.3 * w).truncatingRemainder(dividingBy: 2 * .pi)) < 1e-9)
            #expect(circularDistance(loud.phase(layer), (2.0 * w).truncatingRemainder(dividingBy: 2 * .pi)) < 1e-9)
        }
    }

    @Test func phaseStaysWrapped() {
        var motion = WaveMotion()
        for i in 0..<1_000_000 {
            let level = Float(i % 7) / 6
            motion.advance(layers: [level, 1 - level, 1], dt: 1.0 / 60)
        }
        for layer in WaveLayer.allCases {
            let p = motion.phase(layer)
            #expect(p >= 0 && p < 2 * Double.pi)
        }
    }

    @Test func motionIgnoresNonFiniteInput() {
        var motion = WaveMotion()
        motion.advance(layers: [.nan, .infinity, -.infinity], dt: .nan)
        motion.advance(layers: [.nan, .infinity, 0.5], dt: .infinity)
        motion.advance(layers: [.nan, .infinity, 0.5], dt: -1)
        motion.advance(layers: [], dt: 1)
        for layer in WaveLayer.allCases {
            let p = motion.phase(layer)
            #expect(p.isFinite && p >= 0 && p < 2 * Double.pi)
        }
        // NaN-уровень считается тишиной, бесконечный dt шагом 0, отрицательный тоже.
        var reference = WaveMotion()
        reference.advance(layers: [0, 0, 0], dt: 1)
        motion = WaveMotion()
        motion.advance(layers: [.nan, .nan, .nan], dt: 1)
        for layer in WaveLayer.allCases {
            #expect(motion.phase(layer) == reference.phase(layer))
        }
    }

    // MARK: - BeatPulse

    /// Удар как у `Analyzer`: огибающая взводится на кадре `triggerFrame` и спадает.
    private func pulseResponse(fps: Double, seconds: Double, triggerFrame: Int = 1) -> [Float] {
        let dt = 1 / fps
        var envelope = BeatEnvelope()
        var pulse = BeatPulse()
        var values: [Float] = []
        for frame in 0..<Int(seconds * fps) {
            envelope.step(dt: dt)
            if frame == triggerFrame { envelope.trigger() }
            values.append(pulse.step(beat: envelope.value, dt: dt))
        }
        return values
    }

    @Test func pulseStaysAtRestInSilence() {
        var pulse = BeatPulse()
        for _ in 0..<240 {
            #expect(pulse.step(beat: 0, dt: 1.0 / 120) == 0)
        }
        #expect(pulse.value == 0)
    }

    @Test func pulseInhalesQuicklyAndExhalesSlowly() {
        let fps = 120.0
        let values = pulseResponse(fps: fps, seconds: 2)
        let peakIndex = values.indices.max { values[$0] < values[$1] }!
        let peakTime = Double(peakIndex - 1) / fps
        #expect(values[peakIndex] >= 0.7 && values[peakIndex] <= 0.95, "peak \(values[peakIndex])")
        #expect(peakTime >= 0.03 && peakTime <= 0.1, "peak at \(peakTime) s")
        // Без скачков между соседними кадрами.
        let largestStep = zip(values, values.dropFirst()).map { abs($1 - $0) }.max()!
        #expect(largestStep < 0.25, "step \(largestStep)")
        // Выдох длиннее вдоха, через 1.5 с остров снова в покое.
        #expect(values[Int(0.25 * fps)] > 0.15)
        #expect(values[Int(1.5 * fps)] < 0.01)
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func pulseDoesNotDependOnFrameRate() {
        let at60 = pulseResponse(fps: 60, seconds: 1, triggerFrame: 1)
        let at120 = pulseResponse(fps: 120, seconds: 1, triggerFrame: 2)
        for time in [0.05, 0.1, 0.2, 0.4] {
            let a = at60[Int(time * 60) + 1], b = at120[Int(time * 120) + 2]
            #expect(abs(a - b) < 0.12, "t \(time): \(a) vs \(b)")
        }
    }

    @Test func pulseIgnoresInvalidInput() {
        var pulse = BeatPulse()
        pulse.step(beat: .nan, dt: 1.0 / 60)
        pulse.step(beat: .infinity, dt: .nan)
        pulse.step(beat: 1, dt: -1)
        pulse.step(beat: 1, dt: 0)
        #expect(pulse.value == 0)
        // Длинный кадр и удар на каждом кадре: значение остается в 0...1.
        for _ in 0..<50 {
            let value = pulse.step(beat: 1, dt: 0.1)
            #expect(value >= 0 && value <= 1)
        }
        pulse.step(beat: 1, dt: .infinity)
        #expect(pulse.value.isFinite && pulse.value >= 0 && pulse.value <= 1)
    }

    // MARK: - WavePaint

    private static let warm = [RGBColor(hex: 0xFF8A3D), RGBColor(hex: 0xFFC857), RGBColor(hex: 0xF2545B)]

    private func colorDistance(_ a: RGBColor, _ b: RGBColor) -> Float {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    @Test func paintStopsSpanTheWave() {
        let stops = WavePaint.stops(palette: Self.warm, layer: .mid, level: 0.6, time: 3, count: 9)
        #expect(stops.count == 9)
        for (index, stop) in stops.enumerated() {
            #expect(abs(stop.location - Double(index) / 8) < 1e-12)
            #expect(stop.opacity >= 0 && stop.opacity <= 1)
        }
        #expect(WavePaint.stops(palette: Self.warm, layer: .mid, level: 0.6, time: 3, count: 1).isEmpty)
    }

    @Test func loudWaveBlendsTwoPaletteColors() {
        for layer in WaveLayer.allCases {
            let stops = WavePaint.stops(palette: Self.warm, layer: layer, level: 1, time: 0, count: 9)
            let own = Self.warm[layer.rawValue]
            let next = Self.warm[(layer.rawValue + 1) % 3]
            // При time = 0 у выреза свой цвет слоя, посередине следующий цвет палитры.
            #expect(colorDistance(stops[0].color, own) < 0.01)
            #expect(colorDistance(stops[4].color, next) < 0.01)
            #expect(abs(stops[4].opacity - WavePaint.fullOpacity) < 1e-6)
        }
    }

    @Test func silentWaveIsDimAndColorless() {
        for layer in WaveLayer.allCases {
            for stop in WavePaint.stops(palette: Self.warm, layer: layer, level: 0, time: 7.3, count: 9) {
                let c = stop.color
                #expect(max(c.r, c.g, c.b) - min(c.r, c.g, c.b) < 0.01)
                #expect(stop.opacity <= WavePaint.restOpacity + 1e-6)
            }
        }
        // Цвет и яркость растут вместе с уровнем.
        let quiet = WavePaint.stops(palette: Self.warm, layer: .bass, level: 0.1, time: 0, count: 9)[4]
        let loud = WavePaint.stops(palette: Self.warm, layer: .bass, level: 0.6, time: 0, count: 9)[4]
        #expect(quiet.opacity < loud.opacity)
        let spread: (RGBColor) -> Float = { max($0.r, $0.g, $0.b) - min($0.r, $0.g, $0.b) }
        #expect(spread(quiet.color) < spread(loud.color))
    }

    @Test func wavesFadeAtBothEnds() {
        let stops = WavePaint.stops(palette: Self.warm, layer: .high, level: 1, time: 0, count: 9)
        #expect(stops[8].opacity == 0)
        #expect(stops[0].opacity < 0.1 * WavePaint.fullOpacity)
        #expect(stops[0].opacity < stops[1].opacity && stops[1].opacity < stops[2].opacity)
        #expect(stops[6].opacity > stops[7].opacity && stops[7].opacity > stops[8].opacity)
    }

    @Test func gradientFlowsOutwardAndLoops() {
        // За 2.5 с градиент сдвигается на 0.125 ширины от выреза наружу, за 20 с на всю ширину.
        let now = WavePaint.stops(palette: Self.warm, layer: .bass, level: 1, time: 4, count: 9)
        let later = WavePaint.stops(palette: Self.warm, layer: .bass, level: 1, time: 6.5, count: 9)
        for index in 1..<9 {
            #expect(colorDistance(later[index].color, now[index - 1].color) < 0.005)
        }
        let loop = WavePaint.stops(palette: Self.warm, layer: .bass, level: 1, time: 24, count: 9)
        for index in 0..<9 {
            #expect(colorDistance(loop[index].color, now[index].color) < 0.005)
        }
    }

    @Test func paintSurvivesBadInput() {
        for stop in WavePaint.stops(palette: [], layer: .high, level: .nan, time: .infinity, count: 5) {
            #expect(stop.color.r.isFinite && stop.color.g.isFinite && stop.color.b.isFinite)
            #expect(stop.opacity.isFinite && stop.opacity >= 0 && stop.opacity <= 1)
        }
        let short = WavePaint.stops(palette: [RGBColor(hex: 0x22D3EE)], layer: .high, level: 1, time: 0, count: 3)
        #expect(short.count == 3)
    }
}
