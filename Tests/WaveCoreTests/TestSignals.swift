import Foundation

/// Небольшой seedable генератор только для тестов (SplitMix64).
struct TestRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Равномерное значение в [-1, 1).
    mutating func nextUnit() -> Float {
        let v = Double(next() >> 11) / Double(1 << 53)
        return Float(v * 2 - 1)
    }
}

enum TestSignals {
    static func sine(frequency: Double, amplitude: Float, sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { i in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    static func silence(count: Int) -> [Float] {
        [Float](repeating: 0, count: count)
    }

    static func whiteNoise(amplitude: Float, count: Int, seed: UInt64) -> [Float] {
        var rng = TestRNG(seed: seed)
        return (0..<count).map { _ in amplitude * rng.nextUnit() }
    }

    static func square(frequency: Double, amplitude: Float, sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { i in
            let phase = (frequency * Double(i) / sampleRate).truncatingRemainder(dividingBy: 1)
            return phase < 0.5 ? amplitude : -amplitude
        }
    }

    /// Клик: 20 мс затухающего синуса 60 Гц амплитуды 0.9 в моменты ударов.
    static func clickTrack(bpm: Double, sampleRate: Double, seconds: Double) -> (samples: [Float], beatTimes: [Double]) {
        let total = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: total)
        var beatTimes: [Double] = []
        let interval = 60.0 / bpm
        let clickLength = Int(0.020 * sampleRate)
        var t = 0.0
        while t < seconds {
            beatTimes.append(t)
            let start = Int((t * sampleRate).rounded())
            for k in 0..<clickLength where start + k < total {
                let time = Double(k) / sampleRate
                let envelope = exp(-time / 0.005)
                samples[start + k] += 0.9 * Float(envelope * sin(2 * Double.pi * 60 * time))
            }
            t += interval
        }
        return (samples, beatTimes)
    }
}
