import Foundation
import Testing
@testable import WaveCore

/// Шаг анализа не выделяет память под рабочие буферы, а БПФ после ускорения дает спектр бит в
/// бит как прежний скалярный (образец повторен здесь).
struct HopBuffersTests {
    /// 1000 шагов на музыке, тишине и мусоре (NaN, бесконечность): рабочие буферы шага и БПФ те же
    /// самые (адрес и длина), ни один не пересоздан и не вырос.
    @Test func thousandHopsReuseTheSameBuffers() {
        for rate in [48_000.0, 96_000] {
            let analyzer = StreamAnalyzer(sampleRate: rate)
            let size = analyzer.config.fftSize
            let hop = analyzer.config.hopSize
            let signal = TestSignals.sine(frequency: 80, amplitude: 0.5, sampleRate: rate, count: size + 1000 * hop)
            let before = analyzer.workBuffers
            #expect(before.count == 5)
            #expect(Set(before.map(\.address)).count == before.count)
            for index in 0..<1000 {
                let end = size + index * hop
                var window = Array(signal[(end - size)..<end])
                if index % 97 == 0 { window[index % size] = .nan }
                if index % 89 == 0 { window[(index * 7) % size] = .infinity }
                if (300..<400).contains(index) { window = [Float](repeating: 0, count: size) }
                let result = window.withUnsafeBufferPointer {
                    analyzer.processHop(window: $0, endSample: end, settings: LevelSettings())
                }
                #expect(result.frame.bands.count == BandMapper.bandCount)
                if index % 250 == 0 {
                    #expect(analyzer.workBuffers == before, "hop \(index)")
                }
            }
            #expect(analyzer.workBuffers == before)
        }
    }

    @Test func spectrumMatchesScalarReferenceBitForBit() {
        var generator = SplitMix(seed: 7)
        for size in [2, 4, 8, 16, 32, 64, 256, 1024, 2048, 4096] {
            let fft = RealFFT(size: size)
            var output = [Float](repeating: -1, count: size / 2)
            for trial in 0..<6 {
                let samples: [Float] = (0..<size).map { index in
                    switch trial {
                    case 0: return 0
                    case 1: return index == 0 ? 1 : 0
                    case 2: return Float(sin(Double(index) * 0.37)) * 0.8
                    case 3: return Float(generator.unit() * 2 - 1)
                    case 4: return Float(generator.unit() * 2e4 - 1e4)
                    default: return Float(generator.unit() * 2e-6 - 1e-6)
                    }
                }
                let reference = Self.scalarSpectrum(samples)
                samples.withUnsafeBufferPointer { samples in
                    output.withUnsafeMutableBufferPointer { fft.amplitudeSpectrum(samples, into: $0) }
                }
                #expect(output.map(\.bitPattern) == reference.map(\.bitPattern), "size \(size) trial \(trial)")
                #expect(fft.amplitudeSpectrum(samples).map(\.bitPattern) == reference.map(\.bitPattern))
            }
        }
    }

    // MARK: - Образец: скалярный БПФ до 1.1

    private static func scalarSpectrum(_ samples: [Float]) -> [Float] {
        let size = samples.count
        let half = size / 2
        var windowSum = 0.0
        let window = (0..<size).map { n -> Float in
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(size))
            windowSum += w
            return Float(w)
        }
        let scale = Float(2 / windowSum)
        let cosTable = (0..<half).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        let sinTable = (0..<half).map { Float(-sin(2 * Double.pi * Double($0) / Double(size))) }
        let bits = size.trailingZeroBitCount
        var re = [Float](repeating: 0, count: size)
        var im = [Float](repeating: 0, count: size)
        for i in 0..<size {
            var reversed = 0
            for bit in 0..<bits where i & (1 << bit) != 0 {
                reversed |= 1 << (bits - 1 - bit)
            }
            re[reversed] = samples[i] * window[i]
            im[i] = 0
        }
        var length = 2
        while length <= size {
            let halfLength = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for k in 0..<halfLength {
                    let wr = cosTable[k * step]
                    let wi = sinTable[k * step]
                    let a = start + k
                    let b = a + halfLength
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += length
            }
            length <<= 1
        }
        return (0..<half).map { k in (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale }
    }
}

/// Детерминированный генератор для тестов.
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
