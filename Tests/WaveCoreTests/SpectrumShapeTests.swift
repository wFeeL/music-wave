import Foundation
import Testing
@testable import WaveCore

/// Линия «Спектра» через 24 полосы.
struct SpectrumShapeTests {
    private func samples(
        _ bands: [Float], count: Int, profile: WaveProfile = .wing, gain: Double = 1
    ) -> [Float] {
        var output = [Float](repeating: -9, count: max(count, 0))
        output.withUnsafeMutableBufferPointer {
            SpectrumShape.samples(bands: bands, count: count, profile: profile, gain: gain, into: $0)
        }
        return output
    }

    @Test func spectrumPassesThroughBandCenters() {
        let bands = (0..<24).map { Float($0) / 23 * 0.5 }
        let y = samples(bands, count: 24)
        #expect(y.count == 24)
        for i in 0..<24 {
            #expect(abs(y[i] - bands[i]) <= 1e-4, "\(i): \(y[i]) vs \(bands[i])")
        }
    }

    @Test func spectrumBassAtNotch() {
        var bands = [Float](repeating: 0, count: 24)
        bands[0] = 0.8
        let count = 101
        let y = samples(bands, count: count)
        #expect(abs(y[0] - 0.8) <= 1e-4, "\(y[0])")
        for i in 0..<count where Double(i) / Double(count - 1) > 0.2 {
            #expect(y[i] < 0.01, "\(i): \(y[i])")
        }
    }

    /// Монотонная кубическая кривая не выходит за соседние полосы: между двумя полосами линия
    /// не выше большей из них и не ниже нуля.
    @Test func spectrumNeverOvershoots() {
        var rng = SplitMix64(seed: 7)
        // Восемь точек на промежуток между полосами: точка i лежит на полосе i / 8.
        let count = 23 * 8 + 1
        for round in 0..<50 {
            let bands = (0..<24).map { _ in Float(Double(rng.next() >> 11) / Double(1 << 53)) }
            let y = samples(bands, count: count)
            for i in 0..<count {
                let low = i / 8
                let high = min(low + (i % 8 == 0 ? 0 : 1), 23)
                let ceiling = max(bands[low], bands[high])
                #expect(y[i] >= 0 && y[i] <= 1, "round \(round) point \(i): \(y[i])")
                #expect(y[i] <= ceiling + 1e-5, "round \(round) point \(i): \(y[i]) > \(ceiling)")
            }
            // В панели та же кривая от середины к краям.
            let panel = samples(bands, count: 2 * count - 1, profile: .panel)
            #expect(panel.allSatisfy { $0 >= 0 && $0 <= 1 })
            #expect(panel.max()! <= bands.max()! + 1e-5)
        }
    }

    @Test func spectrumPanelIsSymmetricWithBassInCenter() {
        let bands: [Float] = (0..<24).map { band -> Float in
            let fall = Float(0.7) * Float(23 - band) / 23
            return fall + Float(0.01) * Float(band % 3)
        }
        let count = 47
        let y = samples(bands, count: count, profile: .panel)
        let center = count / 2
        #expect(abs(y[center] - bands[0]) <= 1e-4, "\(y[center])")
        #expect(abs(y[0] - bands[23]) <= 1e-4 && abs(y[count - 1] - bands[23]) <= 1e-4)
        for i in 0..<count {
            #expect(abs(y[i] - y[count - 1 - i]) <= 1e-5, "\(i): \(y[i]) vs \(y[count - 1 - i])")
        }
        // В середине без излома: соседние точки по обе стороны одинаковы и не выше баса.
        let fine = samples(bands, count: 401, profile: .panel)
        #expect(abs(fine[199] - fine[201]) <= 1e-5)
        #expect(fine[199] <= fine[200] + 1e-6)
        // Крыло: та же кривая, бас у выреза.
        let wing = samples(bands, count: 24)
        for i in 0..<24 {
            #expect(abs(wing[i] - y[center + i]) <= 1e-4, "\(i)")
        }
    }

    @Test func spectrumSilentIsFlat() {
        for profile in WaveProfile.allCases {
            #expect(samples([Float](repeating: 0, count: 24), count: 64, profile: profile).allSatisfy { $0 == 0 })
            #expect(samples([], count: 64, profile: profile).allSatisfy { $0 == 0 })
        }
    }

    /// Не конечные и отрицательные полосы считаются нулем, больше 1 ограничиваются, недостающие
    /// полосы это ноль. «Размах» как у волн: не конечный считается 1, отрицательный дает 0.
    @Test func spectrumIgnoresBadInput() {
        let bad: [Float] = [.nan, .infinity, -.infinity, -1, 2, 0.4]
        for profile in WaveProfile.allCases {
            let y = samples(bad, count: 64, profile: profile)
            #expect(y.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(y)")
        }
        let wing = samples(bad, count: 24)
        #expect(wing[0] == 0 && wing[1] == 0 && wing[2] == 0 && wing[3] == 0)
        #expect(abs(wing[4] - Float(WaveShape.softLimit(1))) <= 1e-6)
        #expect(abs(wing[5] - 0.4) <= 1e-4)
        #expect(wing[6...].allSatisfy { $0 == 0 })
        // Полосы сверх 24 не читаются.
        let extra = [Float](repeating: 0, count: 24) + [1, 1]
        #expect(samples(extra, count: 64).allSatisfy { $0 == 0 })

        let bands = (0..<24).map { Float($0) / 23 * 0.5 }
        #expect(samples(bands, count: 24, gain: .nan) == samples(bands, count: 24))
        #expect(samples(bands, count: 24, gain: -2).allSatisfy { $0 == 0 })
        // Размах до колена ровно в `gain` раз, дальше мягкий предел.
        let doubled = samples(bands, count: 24, gain: 1.5)
        #expect(abs(doubled[10] - 1.5 * bands[10]) <= 1e-4)
        #expect(samples(bands, count: 24, gain: 10).allSatisfy { $0 <= 1 })
        // Пустой буфер и одна точка не падают.
        #expect(samples(bands, count: 0).isEmpty)
        #expect(samples(bands, count: 1) == [0])
    }
}
