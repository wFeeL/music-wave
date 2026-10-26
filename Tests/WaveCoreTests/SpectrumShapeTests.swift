import Foundation
import Testing
@testable import WaveCore

/// Линия «Спектра» через 24 полосы: гауссово сглаживание по полосам, кубический B-сплайн,
/// бегущая рябь и «дыхание».
struct SpectrumShapeTests {
    private func samples(
        _ bands: [Float], count: Int, profile: WaveProfile = .wing, gain: Double = 1, smoothing: Double = 1,
        ripple: SpectrumShape.Ripple = .none
    ) -> [Float] {
        var output = [Float](repeating: -9, count: max(count, 0))
        output.withUnsafeMutableBufferPointer {
            SpectrumShape.samples(
                bands: bands, count: count, profile: profile, gain: gain, smoothing: smoothing, ripple: ripple, into: $0
            )
        }
        return output
    }

    private static func random(_ rng: inout SplitMix64, scale: Float = 1) -> [Float] {
        (0..<24).map { _ in Float(Double(rng.next() >> 11) / Double(1 << 53)) * scale }
    }

    private static let ripple = SpectrumShape.Ripple(phase: WavePhase(carrier: 1.3, harmonic: 4.1))

    /// σ в полосах по ширине половины линии: clamp(144 pt / ширина, 1, 3).
    @Test func sigmaFollowsTheWidth() {
        #expect(SpectrumShape.sigma(halfWidth: 64) == 2.25)
        #expect(SpectrumShape.sigma(halfWidth: 144) == 1)
        #expect(SpectrumShape.sigma(halfWidth: 200) == 1)
        #expect(SpectrumShape.sigma(halfWidth: 316) == 1)
        #expect(SpectrumShape.sigma(halfWidth: 72) == 2)
        #expect(SpectrumShape.sigma(halfWidth: 40) == 3)
        #expect(SpectrumShape.sigma(halfWidth: 0) == 3)
        #expect(SpectrumShape.sigma(halfWidth: -5) == 3)
        #expect(SpectrumShape.sigma(halfWidth: .nan) == 3)
        #expect(SpectrumShape.sigma(halfWidth: .infinity) == 1)
    }

    /// Ровные полосы дают ровную линию на высоте уровня × компенсация пика `1 + 0.1 σ`, и в
    /// крыле, и в панели.
    @Test func flatInFlatOut() {
        for sigma in [0.0, 1, 2.25, 3] {
            for profile in WaveProfile.allCases {
                let y = samples([Float](repeating: 0.5, count: 24), count: 64, profile: profile, smoothing: sigma)
                let expected = Float(0.5 * (1 + 0.1 * sigma))
                #expect(y.allSatisfy { abs($0 - expected) <= 1e-6 }, "σ \(sigma) \(profile): \(y)")
            }
        }
    }

    /// Любой вход дает 0...1, в том числе с рябью, «дыханием» и большим «Размахом».
    @Test func outputStaysInUnitRange() {
        var rng = SplitMix64(seed: 7)
        let lifted = SpectrumShape.Ripple(phase: WavePhase(carrier: 2, harmonic: 5), floor: 0.04)
        for round in 0..<50 {
            let bands = Self.random(&rng)
            for profile in WaveProfile.allCases {
                for gain in [1.0, 2, 10] {
                    for ripple in [SpectrumShape.Ripple.none, Self.ripple, lifted] {
                        let y = samples(bands, count: 64, profile: profile, gain: gain, smoothing: 2, ripple: ripple)
                        #expect(y.allSatisfy { $0 >= 0 && $0 <= 1 }, "round \(round) \(profile) gain \(gain)")
                    }
                }
            }
        }
    }

    /// Панель симметрична, бас в середине, середина без излома; крыло это правая половина панели.
    @Test func panelIsSymmetricWithBassInCenter() {
        var rng = SplitMix64(seed: 9)
        let bands = Self.random(&rng)
        for ripple in [SpectrumShape.Ripple.none, Self.ripple] {
            let count = 224
            let y = samples(bands, count: count, profile: .panel, smoothing: 1, ripple: ripple)
            for i in 0..<count {
                #expect(y[i] == y[count - 1 - i], "\(i): \(y[i]) vs \(y[count - 1 - i])")
            }
        }
        // Нечетное число точек: средняя точка лежит на басу, без ряби панель на тех же точках, что и крыло.
        let panel = samples(bands, count: 47, profile: .panel, smoothing: 2)
        let wing = samples(bands, count: 24, profile: .wing, smoothing: 2)
        for i in 0..<24 {
            #expect(abs(panel[23 + i] - wing[i]) <= 1e-6, "\(i)")
        }
        // У баса касательная нулевая: соседние точки по обе стороны середины на одной высоте.
        let fine = samples(bands, count: 401, profile: .panel, smoothing: 1, ripple: Self.ripple)
        #expect(fine[199] == fine[201])
    }

    /// Удар в одной полосе расходится на соседние (не меньше трех полос заметно выше нуля), без
    /// отрицательных лепестков; бас у выреза.
    @Test func impulseSpreadsWithoutNegativeLobes() {
        for band in [0, 10, 23] {
            var bands = [Float](repeating: 0, count: 24)
            bands[band] = 1
            let y = samples(bands, count: 24, smoothing: SpectrumShape.minimumSigma)
            let top = y.max()!
            #expect(y.allSatisfy { $0 >= 0 })
            #expect(y.filter { $0 > 0.05 * top }.count >= 3, "band \(band): \(y)")
            #expect(y.firstIndex(of: top) == band)
        }
    }

    /// Кривая C2: вторая разность соседних точек не больше 2h², где h шаг точек в полосах (вторая
    /// производная B-сплайна по контрольным точкам в 0...1 не больше 2). Вход ниже колена мягкого
    /// предела, чтобы мерить саму кривую.
    @Test func secondDifferenceIsBounded() {
        var rng = SplitMix64(seed: 13)
        let count = 64
        let h = 23.0 / Double(count - 1)
        let bound = Float(2 * h * h)
        var worst: Float = 0
        for _ in 0..<200 {
            let bands = Self.random(&rng, scale: 0.7)
            for sigma in [0.0, 1] {
                let y = samples(bands, count: count, smoothing: sigma)
                for i in 1..<(count - 1) {
                    worst = max(worst, abs(y[i + 1] - 2 * y[i] + y[i - 1]))
                }
            }
        }
        #expect(worst <= bound, "\(worst) > \(bound)")
        // Чередование 0 и 1 (худший гребень) со сглаживанием почти ровное.
        let comb = (0..<24).map { Float($0 % 2) }
        let y = samples(comb, count: count, smoothing: 1)
        let spread = y.max()! - y.min()!
        #expect(spread < 0.1, "\(spread)")
    }

    /// Рябь с глубиной 0 дает ту же линию бит в бит, что и без ряби.
    @Test func zeroRippleEqualsNoRipple() {
        var rng = SplitMix64(seed: 17)
        for _ in 0..<10 {
            let bands = Self.random(&rng)
            for profile in WaveProfile.allCases {
                var flat = Self.ripple
                flat.depth = 0
                #expect(samples(bands, count: 64, profile: profile, smoothing: 2, ripple: flat)
                    == samples(bands, count: 64, profile: profile, smoothing: 2))
            }
        }
        #expect(SpectrumShape.Ripple.none.depth == 0 && SpectrumShape.Ripple.none.floor == 0)
        #expect(Self.ripple.depth == 0.12 && Self.ripple.floor == 0)
    }

    /// Тишина дает ровно 0 и с рябью: рябь умножает линию, а не прибавляется к ней.
    @Test func silenceIsExactlyZeroWithRipple() {
        for profile in WaveProfile.allCases {
            for ripple in [SpectrumShape.Ripple.none, Self.ripple] {
                #expect(samples([Float](repeating: 0, count: 24), count: 64, profile: profile, smoothing: 2.25, ripple: ripple)
                    .allSatisfy { $0 == 0 })
                #expect(samples([], count: 64, profile: profile, ripple: ripple).allSatisfy { $0 == 0 })
            }
        }
        // «Дыхание» в тишине: медленная громкость ниже порога детектора простоя дает пол ровно 0.
        #expect(SpectrumShape.Ripple.floor(slowLevel: 0) == 0)
        #expect(SpectrumShape.Ripple.floor(slowLevel: RenderIdleDetector.level / 2) == 0)
        #expect(SpectrumShape.Ripple.floor(slowLevel: .nan) == 0)
        #expect(abs(SpectrumShape.Ripple.floor(slowLevel: 0.5) - 0.02) < 1e-9)
        #expect(SpectrumShape.Ripple.floor(slowLevel: 3) == 0.04)
    }

    /// Рябь: множитель `1 + 0.12 w(u)` с 1.25 периода на крыло, гребень бежит от выреза наружу,
    /// когда фаза растет.
    @Test func rippleTravelsOutward() {
        let bands = [Float](repeating: 0.5, count: 24)
        let base = Float(0.5 * 1.1)
        var crests: [Int] = []
        for step in 0..<4 {
            let ripple = SpectrumShape.Ripple(phase: WavePhase(carrier: 0, harmonic: 0).shifted(by: 0.2 * Double(step)))
            let y = samples(bands, count: 64, smoothing: 1, ripple: ripple)
            let low = y.min()!, high = y.max()!
            #expect(high <= base * 1.12 + 1e-6 && low >= base * 0.88 - 1e-6, "\(low)...\(high)")
            #expect(high - low > base * 0.15, "\(low)...\(high)")
            // Первый гребень от выреза.
            crests.append((1..<63).first { y[$0] >= y[$0 - 1] && y[$0] > y[$0 + 1] }!)
        }
        #expect(crests == crests.sorted() && crests.first! < crests.last!, "\(crests)")
    }

    /// «Дыхание» поднимает линию на `floor` в середине крыла, у выреза и у края подъема нет; в
    /// панели нет подъема только у краев.
    @Test func floorLiftsTheMiddle() {
        let lifted = SpectrumShape.Ripple(phase: WavePhase(carrier: 0, harmonic: 0), depth: 0, floor: 0.04)
        let silent = [Float](repeating: 0, count: 24)
        let wing = samples(silent, count: 65, smoothing: 1, ripple: lifted)
        #expect(wing[0] == 0 && wing[64] == 0)
        #expect(abs(wing[32] - 0.04) < 1e-6)
        #expect(wing.allSatisfy { $0 >= 0 && $0 <= 0.04 + 1e-6 })
        let panel = samples(silent, count: 65, profile: .panel, smoothing: 1, ripple: lifted)
        #expect(panel[0] == 0 && panel[64] == 0)
        #expect(abs(panel[32] - 0.04) < 1e-6)
    }

    /// Не конечные и отрицательные полосы считаются нулем, больше 1 ограничиваются, недостающие
    /// полосы это ноль, лишние не читаются. «Размах» как у волн: не конечный считается 1,
    /// отрицательный дает 0. σ вне 0...3 ограничивается, не конечное считается 0; глубина ряби и
    /// пол вне 0...1 ограничиваются, не конечные считаются 0.
    @Test func ignoresBadInput() {
        let bad: [Float] = [.nan, .infinity, -.infinity, -1, 2, 0.4]
        for profile in WaveProfile.allCases {
            let y = samples(bad, count: 64, profile: profile, smoothing: 2, ripple: Self.ripple)
            #expect(y.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(y)")
        }
        let clean: [Float] = [0, 0, 0, 0, 1, 0.4]
        #expect(samples(bad, count: 64) == samples(clean, count: 64))
        #expect(samples(clean + [Float](repeating: 0, count: 18) + [1, 1], count: 64) == samples(clean, count: 64))

        var rng = SplitMix64(seed: 21)
        let bands = Self.random(&rng, scale: 0.5)
        #expect(samples(bands, count: 64, gain: .nan) == samples(bands, count: 64))
        #expect(samples(bands, count: 64, gain: -2).allSatisfy { $0 == 0 })
        // Размах до колена ровно в `gain` раз, дальше мягкий предел.
        let single = samples(bands, count: 64), doubled = samples(bands, count: 64, gain: 1.5)
        for i in 0..<64 where 1.5 * single[i] < 0.8 {
            #expect(abs(doubled[i] - 1.5 * single[i]) <= 1e-5)
        }
        #expect(samples(bands, count: 64, smoothing: 7) == samples(bands, count: 64, smoothing: 3))
        #expect(samples(bands, count: 64, smoothing: -1) == samples(bands, count: 64, smoothing: 0))
        #expect(samples(bands, count: 64, smoothing: .nan) == samples(bands, count: 64, smoothing: 0))
        var wild = Self.ripple
        wild.depth = .nan
        wild.floor = .infinity
        #expect(samples(bands, count: 64, ripple: wild) == samples(bands, count: 64))
        wild.depth = 5
        wild.floor = 5
        var capped = Self.ripple
        capped.depth = 1
        capped.floor = 1
        #expect(samples(bands, count: 64, ripple: wild) == samples(bands, count: 64, ripple: capped))
        // Пустой буфер и одна точка не падают.
        #expect(samples(bands, count: 0).isEmpty)
        #expect(samples(bands, count: 1).count == 1)
    }

    /// Старый вызов без σ и ряби (приложение до подключения нового «Спектра»): σ крыла по ширине
    /// по умолчанию, в панели наименьшее, без ряби.
    @Test func legacyCallUsesDefaultSmoothing() {
        var rng = SplitMix64(seed: 23)
        let bands = Self.random(&rng)
        for profile in WaveProfile.allCases {
            var legacy = [Float](repeating: 0, count: 64)
            legacy.withUnsafeMutableBufferPointer {
                SpectrumShape.samples(bands: bands, count: 64, profile: profile, gain: 1.2, into: $0)
            }
            let sigma = profile == .wing ? SpectrumShape.sigma(halfWidth: WaveAppearance.standard.wingWidth) : 1
            #expect(legacy == samples(bands, count: 64, profile: profile, gain: 1.2, smoothing: sigma))
        }
    }
}
