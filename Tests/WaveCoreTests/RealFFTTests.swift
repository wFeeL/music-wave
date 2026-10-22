import Foundation
import Testing
@testable import WaveCore

private let sampleRate = 48_000.0
private let fftSize = 2048

private func binFrequency(_ bin: Int) -> Double {
    Double(bin) * sampleRate / Double(fftSize)
}

private func peakIndex(_ spectrum: [Float]) -> Int {
    spectrum.indices.max(by: { spectrum[$0] < spectrum[$1] })!
}

@Test func sineAtBinCenterGivesUnitPeak() {
    let fft = RealFFT(size: fftSize)
    let bin = 43
    let spec = fft.amplitudeSpectrum(TestSignals.sine(frequency: binFrequency(bin), amplitude: 1, sampleRate: sampleRate, count: fftSize))
    #expect(spec.count == 1024)
    #expect(peakIndex(spec) == bin)
    #expect(abs(spec[bin] - 1) < 0.02)
}

@Test func amplitudeScalesLinearly() {
    let fft = RealFFT(size: fftSize)
    let bin = 100
    let spec = fft.amplitudeSpectrum(TestSignals.sine(frequency: binFrequency(bin), amplitude: 0.25, sampleRate: sampleRate, count: fftSize))
    #expect(peakIndex(spec) == bin)
    #expect(abs(spec[bin] - 0.25) < 0.01)
}

@Test func silenceGivesZeros() {
    let fft = RealFFT(size: fftSize)
    let spec = fft.amplitudeSpectrum(TestSignals.silence(count: fftSize))
    #expect(spec.count == 1024)
    #expect(spec.allSatisfy { $0 == 0 })
}

@Test func denormalInputHasNoNaN() {
    let fft = RealFFT(size: fftSize)
    let spec = fft.amplitudeSpectrum([Float](repeating: 1e-40, count: fftSize))
    #expect(spec.count == 1024)
    #expect(spec.allSatisfy { $0.isFinite })
}

@Test func leakageFarFromPeakIsSmall() {
    let fft = RealFFT(size: fftSize)
    let bin = 300
    let spec = fft.amplitudeSpectrum(TestSignals.sine(frequency: binFrequency(bin), amplitude: 1, sampleRate: sampleRate, count: fftSize))
    for k in spec.indices where abs(k - bin) >= 20 {
        #expect(spec[k] < 0.001, "bin \(k) leaks \(spec[k])")
    }
}

#if !DEBUG
@Test func sixHundredTransformsAreFast() {
    let fft = RealFFT(size: fftSize)
    let input = TestSignals.whiteNoise(amplitude: 0.5, count: fftSize, seed: 7)
    let clock = ContinuousClock()
    var checksum: Float = 0
    let elapsed = clock.measure {
        for _ in 0..<600 { checksum += fft.amplitudeSpectrum(input)[10] }
    }
    #expect(checksum.isFinite)
    #expect(elapsed < .milliseconds(500), "took \(elapsed)")
}
#endif
