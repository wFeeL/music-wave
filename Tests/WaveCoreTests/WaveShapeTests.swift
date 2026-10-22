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
}
