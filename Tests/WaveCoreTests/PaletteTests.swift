import Foundation
import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import WaveCore

struct PaletteTests {
    private func distance(_ a: RGBColor, _ b: RGBColor) -> Float {
        a.oklab.distance(to: b.oklab)
    }

    private func image(_ parts: [(hex: UInt32, share: Double)], side: Int = 64) -> [UInt8] {
        var pixels: [UInt8] = []
        let total = side * side
        for part in parts {
            let n = Int((part.share * Double(total)).rounded())
            let r = UInt8((part.hex >> 16) & 0xFF), g = UInt8((part.hex >> 8) & 0xFF), b = UInt8(part.hex & 0xFF)
            for _ in 0..<n { pixels += [r, g, b, 255] }
        }
        while pixels.count < total * 4 { pixels += [0, 0, 0, 255] }
        return Array(pixels.prefix(total * 4))
    }

    @Test func oklabRoundTrip() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<100 {
            let c = RGBColor(
                r: Float(Double(rng.next() >> 11) / Double(1 << 53)),
                g: Float(Double(rng.next() >> 11) / Double(1 << 53)),
                b: Float(Double(rng.next() >> 11) / Double(1 << 53)))
            let back = RGBColor(oklab: c.oklab)
            #expect(abs(back.r - c.r) < 1e-3)
            #expect(abs(back.g - c.g) < 1e-3)
            #expect(abs(back.b - c.b) < 1e-3)
        }
    }

    @Test func knownOKLabValue() {
        let white = RGBColor(hex: 0xFFFFFF).oklab
        #expect(abs(white.l - 1.0) < 1e-3)
        #expect(abs(white.a) < 1e-3)
        #expect(abs(white.b) < 1e-3)
    }

    @Test func splitMixIsDeterministic() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0..<10 { #expect(a.next() == b.next()) }
        var c = SplitMix64(seed: 0)
        #expect(c.next() == 0xE220_A839_7B1D_CDAF)
    }

    @Test func extractsDominantColors() {
        let red = RGBColor(hex: 0xE11D48), blue = RGBColor(hex: 0x2563EB)
        let pixels = image([(0xE11D48, 0.6), (0x2563EB, 0.3), (0x000000, 0.1)])
        let palette = PaletteExtractor.extract(rgba: pixels, width: 64, height: 64)
        #expect(palette.count == 3)
        #expect(palette.map { distance($0, red) }.min()! < 0.1)
        #expect(palette.map { distance($0, blue) }.min()! < 0.1)
    }

    @Test func grayscaleImageFallsBack() {
        var pixels: [UInt8] = []
        for i in 0..<(64 * 64) {
            let v = UInt8(i % 256)
            pixels += [v, v, v, 255]
        }
        #expect(PaletteExtractor.extract(rgba: pixels, width: 64, height: 64) == PaletteExtractor.fallback)
    }

    @Test func transparentImageFallsBack() {
        let pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        #expect(PaletteExtractor.extract(rgba: pixels, width: 64, height: 64) == PaletteExtractor.fallback)
    }

    @Test func alwaysThreeColors() {
        let pixels = image([(0xE11D48, 1.0)])
        let palette = PaletteExtractor.extract(rgba: pixels, width: 64, height: 64)
        #expect(palette.count == 3)
        for c in palette { #expect(c.r.isFinite && c.g.isFinite && c.b.isFinite) }
        for i in 0..<3 {
            for j in (i + 1)..<3 { #expect(distance(palette[i], palette[j]) > 0.01) }
        }
    }

    @Test func darkColorsAreLiftedInGamut() {
        for hex: UInt32 in [0x1E1B4B, 0x2563EB] {
            let pixels = image([(hex, 1.0)])
            let palette = PaletteExtractor.extract(rgba: pixels, width: 64, height: 64)
            #expect(palette.count == 3)
            for c in palette {
                #expect(c.oklab.l >= 0.62 - 1e-3)
                #expect((0...1).contains(c.r) && (0...1).contains(c.g) && (0...1).contains(c.b))
            }
        }
    }

    @Test func mixEndpoints() {
        let a = PaletteExtractor.fallback
        let b = [RGBColor(hex: 0xE11D48), RGBColor(hex: 0x2563EB), RGBColor(hex: 0x10B981)]
        let m0 = mixPalettes(a, b, t: 0), m1 = mixPalettes(a, b, t: 1), mh = mixPalettes(a, b, t: 0.5)
        for i in 0..<3 {
            #expect(distance(m0[i], a[i]) < 1e-3)
            #expect(distance(m1[i], b[i]) < 1e-3)
            let total = distance(a[i], b[i])
            #expect(abs(distance(mh[i], a[i]) - total / 2) < 1e-3)
            #expect(abs(distance(mh[i], b[i]) - total / 2) < 1e-3)
        }
        for t: Float in [1e-6, 1 - 1e-6] {
            let m = mixPalettes(a, b, t: t)
            #expect(m.count == 3)
            let target = t < 0.5 ? a : b
            for i in 0..<3 { #expect(distance(m[i], target[i]) < 1e-3) }
        }
        #expect(mixPalettes(a, b, t: .nan) == mixPalettes(a, b, t: 0))
        #expect(mixPalettes(a, b, t: -3) == mixPalettes(a, b, t: 0))
        #expect(mixPalettes(a, b, t: 9) == mixPalettes(a, b, t: 1))
    }

    @Test func paddingAlwaysYieldsThreeFiniteColors() {
        let gray = RGBColor(hex: 0x808080)
        for input in [[], [gray], [gray, gray], [gray, gray, gray, gray]] {
            let out = PaletteExtractor.ensureThree(input)
            #expect(out.count == 3)
            for c in out { #expect(c.isFinite && (0...1).contains(c.r) && (0...1).contains(c.g) && (0...1).contains(c.b)) }
        }
        let padded = PaletteExtractor.ensureThree([gray])
        #expect(distance(padded[0], padded[1]) > 0.05)
        #expect(distance(padded[0], padded[2]) > 0.05)
        let broken = PaletteExtractor.ensureThree([RGBColor(r: .nan, g: 0, b: 0)])
        #expect(broken.count == 3 && broken.allSatisfy { $0.isFinite })
    }

    @Test func opposingHuesStillGiveThreeColors() {
        // Два противоположных оттенка с равной долей: средний центр мог бы выйти серым.
        let pixels = image([(0xE11D48, 0.5), (0x1DE1B5, 0.5)])
        let palette = PaletteExtractor.extract(rgba: pixels, width: 64, height: 64)
        #expect(palette.count == 3)
        for c in palette { #expect(c.isFinite) }
    }

    // MARK: - PaletteFade

    private static let cold = [RGBColor(hex: 0x3D8BFF), RGBColor(hex: 0x5EEAD4), RGBColor(hex: 0xA78BFA)]

    private func paletteDistance(_ a: [RGBColor], _ b: [RGBColor]) -> Float {
        zip(a, b).map { distance($0, $1) }.max() ?? .infinity
    }

    @Test func fadeHoldsInitialPalette() {
        var fade = PaletteFade(palette: PaletteExtractor.fallback)
        #expect(fade.palette(target: PaletteExtractor.fallback, now: 10) == PaletteExtractor.fallback)
        #expect(fade.palette(target: PaletteExtractor.fallback, now: 99) == PaletteExtractor.fallback)
    }

    @Test func fadeTakesPointEightSeconds() {
        let start = PaletteExtractor.fallback
        var fade = PaletteFade(palette: start)
        #expect(paletteDistance(fade.palette(target: Self.cold, now: 5), start) < 1e-3)
        let middle = fade.palette(target: Self.cold, now: 5.4)
        #expect(paletteDistance(middle, mixPalettes(start, Self.cold, t: 0.5)) < 1e-3)
        // Ease-in-out: в начале медленнее линейного.
        let early = fade.palette(target: Self.cold, now: 5.1)
        let linear = mixPalettes(start, Self.cold, t: 0.125)
        #expect(paletteDistance(early, start) < paletteDistance(linear, start))
        #expect(fade.palette(target: Self.cold, now: 5.8) == Self.cold)
        #expect(fade.palette(target: Self.cold, now: 30) == Self.cold)
        #expect(PaletteFade.duration == 0.8)
    }

    @Test func retargetStartsFromWhatIsShown() {
        var fade = PaletteFade(palette: PaletteExtractor.fallback)
        _ = fade.palette(target: Self.cold, now: 1)
        let shown = fade.palette(target: Self.cold, now: 1.3)
        let warm = [RGBColor(hex: 0xFF8A3D), RGBColor(hex: 0xFFC857), RGBColor(hex: 0xF2545B)]
        let restarted = fade.palette(target: warm, now: 1.3)
        #expect(paletteDistance(restarted, shown) < 1e-3)
        #expect(fade.palette(target: warm, now: 2.1) == warm)
    }

    @Test func fadeReportsInProgress() {
        var fade = PaletteFade(palette: PaletteExtractor.fallback)
        #expect(!fade.isFading)
        _ = fade.palette(target: PaletteExtractor.fallback, now: 1)
        #expect(!fade.isFading)
        _ = fade.palette(target: Self.cold, now: 2)
        #expect(fade.isFading)
        _ = fade.palette(target: Self.cold, now: 2.4)
        #expect(fade.isFading)
        // Переход кончается на первом кадре после `duration`.
        _ = fade.palette(target: Self.cold, now: 2 + PaletteFade.duration + 0.01)
        #expect(!fade.isFading)
        _ = fade.palette(target: PaletteExtractor.fallback, now: 5)
        _ = fade.palette(target: PaletteExtractor.fallback, now: .nan)
        #expect(!fade.isFading)
    }

    @Test func fadeSurvivesOddClocks() {
        var fade = PaletteFade(palette: PaletteExtractor.fallback)
        _ = fade.palette(target: Self.cold, now: 10)
        // Часы назад: переход стоит в начале, не ломается.
        let back = fade.palette(target: Self.cold, now: 9)
        #expect(paletteDistance(back, PaletteExtractor.fallback) < 1e-3)
        #expect(fade.palette(target: Self.cold, now: .nan) == Self.cold)
        #expect(fade.palette(target: Self.cold, now: 11) == Self.cold)
    }

    // MARK: - PaletteFlow

    private func labDistance(_ a: [OKLab], _ b: [OKLab]) -> Float {
        zip(a, b).map { $0.distance(to: $1) }.max() ?? .infinity
    }

    @Test func flowPhaseZeroIsIdentity() {
        let labs = Self.cold.map(\.oklab)
        #expect(PaletteFlow.apply(labs, phase: 0) == labs)
        #expect(PaletteFlow.apply(Self.cold, phase: 0) == Self.cold)
        // Меньше двух цветов течь нечему.
        let one = [RGBColor(hex: 0x22D3EE)]
        #expect(PaletteFlow.apply(one, phase: 0.4) == one)
        #expect(PaletteFlow.apply([OKLab](), phase: 0.4).isEmpty)
        #expect(PaletteFlow.apply(labs, phase: .nan) == labs)
    }

    @Test func flowThirdTurnRotatesLayers() {
        let labs = Self.cold.map(\.oklab)
        let turned = PaletteFlow.apply(labs, phase: 1.0 / 3)
        #expect(labDistance(turned, [labs[1], labs[2], labs[0]]) < 1e-4)
        let twice = PaletteFlow.apply(labs, phase: 2.0 / 3)
        #expect(labDistance(twice, [labs[2], labs[0], labs[1]]) < 1e-4)
        let rgb = PaletteFlow.apply(Self.cold, phase: 1.0 / 3).map(\.oklab)
        #expect(labDistance(rgb, [labs[1], labs[2], labs[0]]) < 1e-4)
        // Посередине между цветами смесь в OKLab.
        let half = PaletteFlow.apply(labs, phase: 0.5 / 3)
        let expected = OKLab(l: (labs[0].l + labs[1].l) / 2, a: (labs[0].a + labs[1].a) / 2, b: (labs[0].b + labs[1].b) / 2)
        #expect(half[0].distance(to: expected) < 1e-4)
    }

    @Test func flowFullTurnReturns() {
        let labs = Self.cold.map(\.oklab)
        #expect(labDistance(PaletteFlow.apply(labs, phase: 1), labs) < 1e-6)
        #expect(labDistance(PaletteFlow.apply(labs, phase: 1 - 1e-9), labs) < 1e-4)
        #expect(labDistance(PaletteFlow.apply(labs, phase: 2.25), PaletteFlow.apply(labs, phase: 0.25)) < 1e-4)
        var flow = PaletteFlow()
        // Полный оборот за период: через 8 с на полной скорости фаза снова 0.
        for _ in 0..<800 { flow.advance(dt: 0.01, speed: 1) }
        #expect(min(flow.phase, 1 - flow.phase) < 1e-6)
    }

    @Test func flowPeriodRange() {
        #expect(PaletteFlow.slowestPeriod == 20)
        #expect(PaletteFlow.fastestPeriod == 8)
        #expect(PaletteFlow.period(speed: 1) == 8)
        #expect(PaletteFlow.period(speed: 0) == nil)
        #expect(abs(PaletteFlow.period(speed: 1e-6)! - 20) < 1e-3)
        #expect(PaletteFlow.period(speed: 0.5) == 14)
        #expect(PaletteFlow.period(speed: 3) == 8)
        #expect(PaletteFlow.period(speed: -1) == nil)
        #expect(PaletteFlow.period(speed: .nan) == nil)
    }

    @Test func flowSpeedZeroFreezesPhase() {
        var flow = PaletteFlow(phase: 0.3)
        flow.advance(dt: 5, speed: 0)
        #expect(flow.phase == 0.3)
        flow.advance(dt: 1, speed: 0.5)
        #expect(abs(flow.phase - (0.3 + 1.0 / 14)) < 1e-12)
    }

    @Test func flowIgnoresBadInput() {
        var flow = PaletteFlow(phase: 0.6)
        flow.advance(dt: .nan, speed: 1)
        flow.advance(dt: -1, speed: 1)
        flow.advance(dt: .infinity, speed: 1)
        flow.advance(dt: 1, speed: .nan)
        flow.advance(dt: 1, speed: -0.5)
        #expect(flow.phase == 0.6)
        #expect(PaletteFlow(phase: .nan).phase == 0)
    }

    @Test func flowInitWrapsPhase() {
        #expect(PaletteFlow(phase: 1.25).phase == 0.25)
        #expect(PaletteFlow(phase: -0.25).phase == 0.75)
        #expect(PaletteFlow(phase: 1).phase == 0)
        #expect(PaletteFlow().phase == 0)
    }

    // MARK: - ArtworkGlow

    /// Свечение обложки только у раскрытой панели, при включенной функции, с обложкой и без
    /// «Уменьшить прозрачность».
    @Test func artworkGlowShownOnlyWhileExpanded() {
        let states: [IslandState] = [.hidden, .collapsed, .expanded]
        var shown = 0
        for state in states {
            for enabled in [false, true] {
                for hasArtwork in [false, true] {
                    for reduceTransparency in [false, true] {
                        let expected = state == .expanded && enabled && hasArtwork && !reduceTransparency
                        let actual = ArtworkGlow.isShown(
                            enabled: enabled, state: state, hasArtwork: hasArtwork,
                            reduceTransparency: reduceTransparency
                        )
                        #expect(
                            actual == expected,
                            "\(state) enabled \(enabled) artwork \(hasArtwork) reduce \(reduceTransparency)"
                        )
                        if actual { shown += 1 }
                    }
                }
            }
        }
        #expect(shown == 1)
    }

    /// Цвета свечения обложки это `WavePaint.glowColor` каждого цвета палитры: темные поднимаются.
    @Test func artworkGlowColorsAreLifted() {
        let dark = [RGBColor(hex: 0x3A1F12), RGBColor(hex: 0x10204A), RGBColor(hex: 0x202020)]
        let colors = ArtworkGlow.colors(artworkPalette: dark)
        #expect(colors == dark.map(WavePaint.glowColor))
        #expect(colors.count == 3)
        for (glow, source) in zip(colors, dark) {
            #expect(glow.oklab.l >= WavePaint.glowLightness - 1e-3)
            #expect(glow.oklab.l > source.oklab.l)
        }
        #expect(ArtworkGlow.colors(artworkPalette: []).isEmpty)
        #expect(ArtworkGlow.opacity == 0.45 && ArtworkGlow.blur == 8 && ArtworkGlow.spread == 4)
    }

    /// Сияние с размытием помещается в поля окна панели и не обрезается краем окна.
    @Test func haloFitsPanelMargins() {
        #expect(ArtworkGlow.reach <= Double(NotchGeometry.panelSideMargin))
        #expect(ArtworkGlow.reach <= Double(NotchGeometry.glowMargin))
        #expect(ArtworkGlow.reach <= Double(NotchGeometry.panelTopMargin))
    }

    /// Прямоугольник сияния шире тела панели на `spread` со всех сторон, скругление концентрично
    /// скруглению тела, прямой угол остается прямым.
    @Test func haloSurroundsPanelBody() {
        let body = CGRect(x: 10, y: 20, width: 468, height: 150)
        let halo = ArtworkGlow.halo(around: body)
        let spread = CGFloat(ArtworkGlow.spread)
        #expect(halo == CGRect(x: 10 - spread, y: 20 - spread, width: 468 + 2 * spread, height: 150 + 2 * spread))
        #expect(ArtworkGlow.cornerRadius(body: 28) == 28 + spread)
        #expect(ArtworkGlow.cornerRadius(body: 0) == 0)
    }
}

/// Цвет линии «Спектра» (`WavePaint.spectrumStops`): кольцо палитры вдоль частот, «Цвет по
/// частотам» без резких краев и подсветка по высоте линии.
struct SpectrumStopsTests {
    private static func stops(
        _ palette: [RGBColor], heights: [Float], level: Float = 1, time: Double = 0, profile: WaveProfile = .wing,
        options: WavePaint.Options = .standard
    ) -> [WavePaint.Stop] {
        WavePaint.spectrumStops(
            palette: palette, heights: heights, level: level, time: time, profile: profile, options: options
        )
    }

    private static func flat(_ height: Float, count: Int = 64) -> [Float] {
        [Float](repeating: height, count: count)
    }

    /// Расстояние от выреза (в панели от середины) для положения точки.
    private static func distance(_ location: Double, _ profile: WaveProfile) -> Double {
        profile == .wing ? location : abs(2 * location - 1)
    }

    /// Оттенок OKLab в градусах.
    private static func hue(_ lab: OKLab) -> Float {
        atan2(lab.b, lab.a) * 180 / .pi
    }

    private static func hueGap(_ x: Float, _ y: Float) -> Float {
        let gap = abs(x - y).truncatingRemainder(dividingBy: 360)
        return min(gap, 360 - gap)
    }

    /// 17 точек с шагом 1/16 и точки проявления у выреза и растворения у края; в панели то же от
    /// середины к обоим краям.
    @Test func locations() {
        let wing = WavePaint.spectrumLocations(for: .wing)
        #expect(wing == wing.sorted() && Set(wing).count == wing.count)
        for k in 0...16 { #expect(wing.contains(Double(k) / 16)) }
        for point in [0.01, 0.02, 0.04, 0.82, 0.86, 0.9, 0.95] { #expect(wing.contains(point)) }
        #expect(wing.count == 24)
        let panel = WavePaint.spectrumLocations(for: .panel)
        #expect(panel == panel.sorted() && Set(panel).count == panel.count)
        #expect(panel.count == 41)
        for location in panel {
            #expect(panel.contains { abs($0 - (1 - location)) < 1e-12 })
        }
        for k in 0...16 { #expect(panel.contains { abs($0 - (0.5 + Double(k) / 32)) < 1e-12 }) }
        for profile in WaveProfile.allCases {
            let result = Self.stops(PaletteExtractor.fallback, heights: Self.flat(0.5), profile: profile)
            #expect(result.map(\.location) == WavePaint.spectrumLocations(for: profile))
        }
    }

    /// Соседние точки близки в OKLab: на шаг цвет меняется не больше, чем позволяет smoothstep
    /// (наклон до 1.5) на доле кольца `0.67 × Δu` между соседними цветами кольца, для любых
    /// палитр, времени и обоих режимов.
    @Test func colorsAreContinuous() {
        let palettes = WavePreset.allCases.map(\.colors) + [PaletteExtractor.fallback]
        for palette in palettes {
            let ring = WavePaint.distinct(palette)
            var widest: Float = 0
            for index in ring.indices {
                widest = max(widest, ring[index].distance(to: ring[(index + 1) % ring.count]))
            }
            for profile in WaveProfile.allCases {
                for colorByBand in [false, true] {
                    for time in [0.0, 3.7, 11.2] {
                        let options = WavePaint.Options(colorByBand: colorByBand, flowPhase: colorByBand ? 0 : 0.3)
                        let result = Self.stops(palette, heights: Self.flat(0.5), time: time, profile: profile, options: options)
                        // «Цвет по частотам»: путь из двух отрезков на всю половину линии, без кольца.
                        let rate = colorByBand ? Double(ring.count - 1) : 0.67 * Double(ring.count)
                        for index in 1..<result.count {
                            let step = abs(Self.distance(result[index].location, profile)
                                - Self.distance(result[index - 1].location, profile))
                            let bound = Float(1.5 * rate * step) * widest + 0.01
                            let gap = result[index].color.oklab.distance(to: result[index - 1].color.oklab)
                            #expect(gap <= bound, "\(palette) \(profile) \(colorByBand) t \(time) #\(index): \(gap) > \(bound)")
                        }
                    }
                }
            }
        }
    }

    /// Кольцо сдвигается на 0.05 в секунду плюс фаза переливания: через 20 с цвета те же, фаза
    /// 0.25 равна 5 с времени.
    @Test func ringShiftPeriod() {
        let palette = WavePreset.rainbow.colors
        for profile in WaveProfile.allCases {
            let start = Self.stops(palette, heights: Self.flat(0.4), time: 2, profile: profile)
            let later = Self.stops(palette, heights: Self.flat(0.4), time: 22, profile: profile)
            let flowed = Self.stops(
                palette, heights: Self.flat(0.4), time: 2, profile: profile, options: WavePaint.Options(flowPhase: 0.25)
            )
            let shifted = Self.stops(palette, heights: Self.flat(0.4), time: 7, profile: profile)
            for index in start.indices {
                #expect(start[index].color.oklab.distance(to: later[index].color.oklab) < 1e-3)
                #expect(flowed[index].color.oklab.distance(to: shifted[index].color.oklab) < 1e-3)
            }
            // Через 5 с цвета другие: кольцо действительно плывет.
            #expect(zip(start, shifted).contains { $0.color.oklab.distance(to: $1.color.oklab) > 0.05 })
        }
    }

    /// Кольцо: у выреза (в панели в середине) в момент 0 первый цвет палитры, к краю цвета идут по
    /// кольцу (0.67 кольца на половину линии), со временем плывут наружу.
    @Test func ringStartsAtTheFirstColorAndFlowsOutward() {
        let palette = WavePreset.rainbow.colors
        let ring = WavePaint.distinct(palette)
        let wing = Self.stops(palette, heights: Self.flat(0), time: 0)
        #expect(Self.hueGap(Self.hue(wing[0].color.oklab), Self.hue(ring[0])) < 2)
        // Точка u = 0.5: кольцо 0.335, чуть дальше второго цвета.
        let middle = wing.first { $0.location == 0.5 }!
        #expect(Self.hueGap(Self.hue(middle.color.oklab), Self.hue(ring[1])) < 15)
        let panel = Self.stops(palette, heights: Self.flat(0, count: 224), time: 0, profile: .panel)
        let center = panel.first { $0.location == 0.5 }!
        #expect(Self.hueGap(Self.hue(center.color.oklab), Self.hue(ring[0])) < 2)
        // Через секунду у выреза цвет, который был чуть внутрь кольца (u < 0): цвета плывут наружу,
        // и точка u = 0.075 (0.05 кольца / 0.67) получает прежний цвет выреза.
        let hue0 = Self.hue(wing[0].color.oklab)
        let later = WavePaint.spectrumStops(
            palette: palette, heights: Self.flat(0), level: 1, time: 1, profile: .wing, options: .standard
        )
        let moved = later.first { abs($0.location - 0.0625) < 1e-12 }!
        #expect(Self.hueGap(Self.hue(moved.color.oklab), hue0) < 3, "\(Self.hue(moved.color.oklab)) vs \(hue0)")
    }

    /// «Цвет по частотам»: цвет баса у выреза, середины в середине, верха у края, от времени не
    /// зависит, переходы на всю треть без краев.
    @Test func colorByBandAnchors() {
        let palette = WavePreset.rainbow.colors
        let ring = WavePaint.distinct(palette)
        let options = WavePaint.Options(colorByBand: true)
        for time in [0.0, 6.3] {
            let wing = Self.stops(palette, heights: Self.flat(0.3), time: time, options: options)
            #expect(Self.hueGap(Self.hue(wing.first!.color.oklab), Self.hue(ring[0])) < 2)
            #expect(Self.hueGap(Self.hue(wing.first { $0.location == 0.5 }!.color.oklab), Self.hue(ring[1])) < 2)
            #expect(Self.hueGap(Self.hue(wing.last!.color.oklab), Self.hue(ring[2])) < 2)
            let panel = Self.stops(palette, heights: Self.flat(0.3, count: 224), time: time, profile: .panel, options: options)
            #expect(Self.hueGap(Self.hue(panel.first { $0.location == 0.5 }!.color.oklab), Self.hue(ring[0])) < 2)
            #expect(Self.hueGap(Self.hue(panel.first!.color.oklab), Self.hue(ring[2])) < 2)
            #expect(Self.hueGap(Self.hue(panel.last!.color.oklab), Self.hue(ring[2])) < 2)
        }
        let first = Self.stops(palette, heights: Self.flat(0.3), time: 0, options: options)
        let second = Self.stops(palette, heights: Self.flat(0.3), time: 6.3, options: options)
        #expect(first == second)
    }

    /// Подсветка по высоте: выше линия, тем светлее, насыщеннее и непрозрачнее точка; в тишине
    /// прозрачность × 0.7, на полной высоте × 1.
    @Test func levelTintIsMonotone() {
        // Приглушенная палитра: подсветка не упирается в гамму sRGB.
        let muted = [RGBColor(hex: 0x8A7F96), RGBColor(hex: 0x7F8F96), RGBColor(hex: 0x96887F)]
        for palette in [muted, WavePreset.neon.colors, WavePreset.mono.colors] {
            var previous: [WavePaint.Stop]?
            for height in stride(from: Float(0), through: 1, by: 0.125) {
                let result = Self.stops(palette, heights: Self.flat(height), time: 1.5)
                if let previous {
                    for index in result.indices {
                        let now = result[index].color.oklab, before = previous[index].color.oklab
                        #expect(now.l >= before.l - 1e-4, "\(height) #\(index)")
                        #expect(result[index].opacity >= previous[index].opacity)
                        if palette == muted {
                            #expect(now.chroma >= before.chroma - 1e-4, "\(height) #\(index)")
                        }
                    }
                }
                previous = result
            }
        }
        let low = Self.stops(muted, heights: Self.flat(0)), high = Self.stops(muted, heights: Self.flat(1))
        for index in low.indices where low[index].opacity > 0 {
            #expect(abs(high[index].opacity / low[index].opacity - 1 / 0.7) < 1e-4)
        }
        // Высота берется в своей точке: горб в середине крыла светлее краев.
        let hump = (0..<64).map { Float(sin(Double.pi * Double($0) / 63)) }
        let humped = Self.stops(muted, heights: hump)
        let middle = humped.first { $0.location == 0.5 }!
        let notch = humped.first!
        #expect(middle.opacity > notch.opacity)
    }

    /// Плохой вход: пустая палитра дает запасную, пустые и не конечные высоты считаются нулем,
    /// не конечное время дает сдвиг 0.
    @Test func badInput() {
        let fallback = Self.stops(PaletteExtractor.fallback, heights: Self.flat(0))
        #expect(Self.stops([], heights: Self.flat(0)) == fallback)
        #expect(Self.stops(PaletteExtractor.fallback, heights: []) == fallback)
        #expect(Self.stops(PaletteExtractor.fallback, heights: Self.flat(.nan)) == fallback)
        #expect(Self.stops(PaletteExtractor.fallback, heights: Self.flat(-3)) == fallback)
        #expect(Self.stops(PaletteExtractor.fallback, heights: Self.flat(0), time: .nan) == fallback)
        let single = Self.stops([RGBColor(hex: 0x40C0FF)], heights: Self.flat(0.5))
        #expect(single.allSatisfy { $0.color.isFinite && $0.opacity.isFinite })
    }
}
