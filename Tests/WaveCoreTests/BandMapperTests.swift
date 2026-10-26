import Foundation
import Testing
@testable import WaveCore

struct BandMapperTests {
    @Test func edgesAreLogSpaced() {
        let m = BandMapper(fftSize: 2048, sampleRate: 48_000)
        #expect(m.edges.count == 25)
        #expect(m.edges.first == 40)
        #expect(m.edges.last == 16_000)
        let expected = m.edges[1] / m.edges[0]
        for i in 1..<24 {
            #expect(abs(m.edges[i + 1] / m.edges[i] - expected) < 1e-9)
        }
        for i in 0..<24 {
            #expect(abs(m.centers[i] - (m.edges[i] * m.edges[i + 1]).squareRoot()) < 1e-9)
        }
    }

    /// Наклон `f^0.35`: 20 × 0.35 × log10(2) = 2.107 dB на октаву между любыми соседними полосами.
    @Test func tiltRisesAboutTwoDecibelsPerOctave() {
        let m = BandMapper(fftSize: 1024, sampleRate: 48_000)
        let tilt = m.tiltDB()
        #expect(tilt.count == BandMapper.bandCount)
        let expected = 20 * 0.35 * log10(2.0)
        for i in 0..<(BandMapper.bandCount - 1) {
            let slope = Double(tilt[i + 1] - tilt[i]) / log2(m.centers[i + 1] / m.centers[i])
            #expect(abs(slope - expected) < 0.01)
        }
    }

    @Test func layersPartitionAllBands() {
        for rate in [44_100.0, 48_000.0] {
            let m = BandMapper(fftSize: 2048, sampleRate: rate)
            var covered: [Int] = []
            for layer in WaveLayer.allCases {
                let range = m.bands(for: layer)
                #expect(!range.isEmpty)
                covered.append(contentsOf: range)
            }
            #expect(covered.sorted() == Array(0..<24))
            #expect(Set(covered).count == covered.count)
        }
    }

    @Test func sine1kHzLandsInMidLayer() {
        for rate in [44_100.0, 48_000.0] {
            let m = BandMapper(fftSize: 2048, sampleRate: rate)
            let spectrum = RealFFT(size: 2048).amplitudeSpectrum(
                TestSignals.sine(frequency: 1000, amplitude: 1, sampleRate: rate, count: 2048))
            let levels = m.bandLevels(spectrum)
            let loudest = levels.indices.max(by: { levels[$0] < levels[$1] })!
            #expect(m.bands(for: .mid).contains(loudest))
            #expect(loudest == m.band(containing: 1000))
            #expect(loudest == 12)
            #expect(levels[loudest] > -3)
        }
    }

    @Test func lowestBandsHaveValuesEvenWithoutBins() {
        let m = BandMapper(fftSize: 2048, sampleRate: 48_000)
        let spectrum = RealFFT(size: 2048).amplitudeSpectrum(
            TestSignals.sine(frequency: 45, amplitude: 1, sampleRate: 48_000, count: 2048))
        let levels = m.bandLevels(spectrum)
        for level in levels {
            #expect(level.isFinite)
        }
        #expect(levels[0] > -12)
    }

    @Test func emptyBandIsInterpolatedNotCopied() {
        let m = BandMapper(fftSize: 2048, sampleRate: 48_000)
        let spectrum = RealFFT(size: 2048).amplitudeSpectrum(
            TestSignals.sine(frequency: 47, amplitude: 1, sampleRate: 48_000, count: 2048))
        let levels = m.bandLevels(spectrum)
        #expect(levels[1] != levels[0])
        #expect(levels[1] > -120)
    }

    @Test func layerAssignment() {
        let m = BandMapper(fftSize: 2048, sampleRate: 48_000)
        #expect(m.bands(for: .bass) == 0..<7)
        #expect(m.bands(for: .mid) == 7..<18)
        #expect(m.bands(for: .high) == 18..<24)
    }

    @Test func silenceGivesFloor() {
        let m = BandMapper(fftSize: 2048, sampleRate: 48_000)
        let levels = m.bandLevels([Float](repeating: 0, count: 1024))
        #expect(levels.count == 24)
        #expect(levels.allSatisfy { $0 == -120 })
    }

    @Test func emptyBandsMatchSampleRate() {
        // 48 кГц: пуста полоса 1, 44.1 кГц: пуста полоса 2 (бин 0 не считается).
        let flat = [Float](repeating: 1, count: 1024)
        let at48 = BandMapper(fftSize: 2048, sampleRate: 48_000).bandLevels(flat)
        let at441 = BandMapper(fftSize: 2048, sampleRate: 44_100).bandLevels(flat)
        // Пустая полоса дает мощность одного бина, непустые с несколькими бинами выше.
        #expect(abs(at48[1] - 10 * log10(1 / 1.5)) < 1e-4)
        #expect(abs(at441[2] - 10 * log10(1 / 1.5)) < 1e-4)
    }

    @Test func edgeFrequencyLookup() {
        let m = BandMapper(fftSize: 2048, sampleRate: 48_000)
        #expect(m.band(containing: 39.9) == nil)
        #expect(m.band(containing: 40) == 0)
        #expect(m.band(containing: 16_000) == 23)
        #expect(m.band(containing: 16_000.1) == nil)
    }
}
