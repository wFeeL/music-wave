import Foundation
import Testing
@testable import WaveCore

struct WaveAppearanceTests {
    @Test func defaultsMatchSpec() {
        #expect(WaveAppearance.standard == WaveAppearance(
            wingWidth: 64, colorMode: .artwork, glowSize: 1, lineCount: 3, fill: 0, thickness: 1, amplitude: 1
        ))
        #expect(WaveAppearance.Limits.wingWidth == 40...200)
        #expect(WaveAppearance.Limits.glowSize == 0.5...3)
        #expect(WaveAppearance.Limits.glowSharpness == 0...1)
        #expect(WaveAppearance.standard.glowSharpness == 0.4)
        #expect(WaveAppearance.Limits.lineCount == 1...6)
        #expect(WaveAppearance.Limits.fill == 0...1)
        #expect(WaveAppearance.Limits.thickness == 0.5...2)
        #expect(WaveAppearance.Limits.amplitude == 0.5...2)
    }

    @Test func clampsRanges() {
        let high = WaveAppearance(
            wingWidth: 300, colorMode: .artwork, glowSize: 5, lineCount: 9, fill: 2, thickness: 3, amplitude: 9
        )
        #expect(high.wingWidth == 200 && high.glowSize == 3 && high.lineCount == 6)
        #expect(high.fill == 1 && high.thickness == 2 && high.amplitude == 2)
        let low = WaveAppearance(
            wingWidth: 10, colorMode: .artwork, glowSize: 0, lineCount: 0, fill: -1, thickness: .nan, amplitude: -.infinity
        )
        #expect(low.wingWidth == 40 && low.glowSize == 0.5 && low.lineCount == 1)
        #expect(low.fill == 0 && low.thickness == 1 && low.amplitude == 1)
        // Запись в свойство ограничивается так же.
        var edited = WaveAppearance.standard
        edited.wingWidth = .infinity
        edited.lineCount = -3
        edited.fill = 0.4
        #expect(edited.wingWidth == 64 && edited.lineCount == 1 && edited.fill == 0.4)
    }

    @Test func codableRoundTrip() throws {
        let samples = [
            WaveAppearance.standard,
            WaveAppearance(
                wingWidth: 180, colorMode: .custom(RGBColor(hex: 0x123456)), glowSize: 2.5,
                lineCount: 6, fill: 0.7, thickness: 1.5, amplitude: 0.5
            ),
            WaveAppearance(wingWidth: 40, colorMode: .preset(.neon), glowSize: 0.5, lineCount: 1, fill: 1, thickness: 2, amplitude: 2),
            WaveAppearance(
                wingWidth: 90, colorMode: .preset(.rainbow), glowSize: 1.5, lineCount: 1, fill: 0.2, thickness: 1,
                amplitude: 1.2, colorFlow: 0.35, colorByBand: true
            ),
            WaveAppearance(
                wingWidth: 72, colorMode: .preset(.ice), glowSize: 1, lineCount: 4, fill: 0.5, thickness: 1,
                amplitude: 1, look: .spectrum
            ),
        ]
        for appearance in samples {
            let data = try JSONEncoder().encode(appearance)
            #expect(try JSONDecoder().decode(WaveAppearance.self, from: data) == appearance)
        }
        // Значения вне диапазона и пропущенные поля при чтении приводятся к допустимым.
        let stored = Data(#"{"wingWidth": 900, "lineCount": 4}"#.utf8)
        let decoded = try JSONDecoder().decode(WaveAppearance.self, from: stored)
        #expect(decoded.wingWidth == 200 && decoded.lineCount == 4)
        #expect(decoded.colorMode == .artwork && decoded.glowSize == 1 && decoded.fill == 0)
    }

    /// Настройки 1.1 без новых полей дают прежний вид: без переливания и без цвета по частотам.
    @Test func appearanceDecodesWithoutNewFields() throws {
        let json = #"{"wingWidth": 120, "colorMode": {"preset": {"_0": "neon"}}, "glowRadius": 2, "lineCount": 5, "#
            + #""fill": 0.4, "thickness": 1.5, "amplitude": 0.8}"#
        let stored = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WaveAppearance.self, from: stored)
        #expect(decoded == WaveAppearance(
            wingWidth: 120, colorMode: .preset(.neon), glowSize: 2, lineCount: 5, fill: 0.4, thickness: 1.5, amplitude: 0.8
        ))
        #expect(decoded.colorFlow == 0)
        #expect(decoded.colorByBand == false)
        #expect(WaveAppearance.standard.colorFlow == 0 && !WaveAppearance.standard.colorByBand)
        // Поле не того типа берется по умолчанию.
        let broken = Data(#"{"colorFlow": "fast", "colorByBand": 1}"#.utf8)
        let fallback = try JSONDecoder().decode(WaveAppearance.self, from: broken)
        #expect(fallback.colorFlow == 0 && !fallback.colorByBand)
    }

    /// Четкость 0, 0.4 и 1 дают размытие 1.5, 1 (как в 1.2) и 0.25; вне 0...1 берется граница.
    @Test func blurScaleFollowsSharpness() {
        func scale(_ sharpness: Double) -> Double {
            WaveAppearance(
                wingWidth: 64, colorMode: .artwork, glowSize: 1, lineCount: 3, fill: 0, thickness: 1, amplitude: 1,
                glowSharpness: sharpness
            ).glowBlurScale
        }
        #expect(abs(scale(0) - 1.5) < 1e-12)
        #expect(abs(scale(0.4) - 1.0) < 1e-12)
        #expect(abs(scale(1) - 0.25) < 1e-12)
        #expect(abs(scale(7) - 0.25) < 1e-12)
        #expect(abs(scale(-1) - 1.5) < 1e-12)
        #expect(abs(WaveAppearance.standard.glowBlurScale - 1) < 1e-12)
        var edited = WaveAppearance.standard
        edited.glowSharpness = .nan
        #expect(edited.glowSharpness == 0.4)
    }

    /// Пятно под островом: ширина `min(0.7 × √размер, 1)`, при размере 1 как в 1.2 (0.7).
    @Test func glowSpotWidthGrowsWithSize() {
        #expect(abs(WaveAppearance.glowSpotWidthFraction(size: 1) - 0.7) < 1e-12)
        #expect(abs(WaveAppearance.glowSpotWidthFraction(size: 2) - 0.7 * 2.0.squareRoot()) < 1e-12)
        #expect(WaveAppearance.glowSpotWidthFraction(size: 3) == 1)
        #expect(abs(WaveAppearance.glowSpotWidthFraction(size: 0.5) - 0.7 * 0.5.squareRoot()) < 1e-12)
        #expect(WaveAppearance.glowSpotWidthFraction(size: .nan) == WaveAppearance.glowSpotWidthFraction(size: 1))
        #expect(WaveAppearance.glowSpotWidthFraction(size: 9) == 1)
    }

    /// Вид 1.2 с ключом `glowRadius` читается как размер; новый ключ главнее старого; пишется только новый.
    @Test func legacyGlowRadiusBecomesSize() throws {
        let old = try JSONDecoder().decode(WaveAppearance.self, from: Data(#"{"glowRadius": 2}"#.utf8))
        #expect(old.glowSize == 2 && old.glowSharpness == 0.4)
        let both = try JSONDecoder().decode(WaveAppearance.self, from: Data(#"{"glowRadius": 2, "glowSize": 1.5}"#.utf8))
        #expect(both.glowSize == 1.5)
        let clamped = try JSONDecoder().decode(WaveAppearance.self, from: Data(#"{"glowRadius": 9}"#.utf8))
        #expect(clamped.glowSize == 3)
        var sharp = WaveAppearance.standard
        sharp.glowSize = 2
        sharp.glowSharpness = 0.9
        let json = String(decoding: try JSONEncoder().encode(sharp), as: UTF8.self)
        #expect(json.contains("glowSize") && json.contains("glowSharpness") && !json.contains("glowRadius"))
        #expect(try JSONDecoder().decode(WaveAppearance.self, from: Data(json.utf8)) == sharp)
    }

    @Test func clampsColorFlow() throws {
        #expect(WaveAppearance.Limits.colorFlow == 0...1)
        func flow(_ value: Double) -> Double {
            WaveAppearance(
                wingWidth: 64, colorMode: .artwork, glowSize: 1, lineCount: 3, fill: 0, thickness: 1, amplitude: 1,
                colorFlow: value
            ).colorFlow
        }
        #expect(flow(0.4) == 0.4)
        #expect(flow(2) == 1)
        #expect(flow(-1) == 0)
        #expect(flow(.nan) == 0)
        #expect(flow(.infinity) == 0)
        var edited = WaveAppearance.standard
        edited.colorFlow = 7
        #expect(edited.colorFlow == 1)
        edited.colorFlow = .nan
        #expect(edited.colorFlow == 0)
        let stored = Data(#"{"colorFlow": 3, "colorByBand": true}"#.utf8)
        let decoded = try JSONDecoder().decode(WaveAppearance.self, from: stored)
        #expect(decoded.colorFlow == 1 && decoded.colorByBand)
    }

    /// Неизвестная готовая палитра дает «Из обложки», остальные поля сохраняются.
    @Test func unknownPresetFallsBackToArtwork() throws {
        let appearance = WaveAppearance(
            wingWidth: 120, colorMode: .preset(.neon), glowSize: 2, lineCount: 5, fill: 0.4, thickness: 1.5, amplitude: 0.8
        )
        let json = String(decoding: try JSONEncoder().encode(appearance), as: UTF8.self)
        #expect(json.contains("\"neon\""))
        let stored = Data(json.replacingOccurrences(of: "\"neon\"", with: "\"plasma\"").utf8)
        let decoded = try JSONDecoder().decode(WaveAppearance.self, from: stored)
        var expected = appearance
        expected.colorMode = .artwork
        #expect(decoded == expected)
    }

    /// Поле не того типа берется по умолчанию, остальные сохраняются.
    @Test func wrongTypedFieldTakesDefault() throws {
        let stored = Data(#"{"wingWidth": "wide", "lineCount": 5, "fill": 0.4, "glowRadius": [2]}"#.utf8)
        let decoded = try JSONDecoder().decode(WaveAppearance.self, from: stored)
        #expect(decoded.wingWidth == WaveAppearance.standard.wingWidth)
        #expect(decoded.glowSize == WaveAppearance.standard.glowSize)
        #expect(decoded.lineCount == 5)
        #expect(decoded.fill == 0.4)
    }

    @Test func lineTable() {
        func main(_ layer: WaveLayer) -> WaveLine {
            WaveLine(source: .layer(layer), shape: layer, phaseOffset: 0, amplitudeScale: 1, opacity: 1)
        }
        let overall = WaveLine(source: .overall, shape: .mid, phaseOffset: 0, amplitudeScale: 1, opacity: 1)
        let echoes = [
            WaveLine(source: .layer(.bass), shape: .bass, phaseOffset: 0.6, amplitudeScale: 0.72, opacity: 0.45),
            WaveLine(source: .layer(.mid), shape: .mid, phaseOffset: 0.6, amplitudeScale: 0.52, opacity: 0.3),
            WaveLine(source: .layer(.high), shape: .high, phaseOffset: 0.6, amplitudeScale: 0.38, opacity: 0.28),
        ]
        let three = [main(.bass), main(.mid), main(.high)]
        #expect(WaveLine.lines(count: 1) == [overall])
        #expect(WaveLine.lines(count: 2) == [main(.bass), main(.high)])
        #expect(WaveLine.lines(count: 3) == three)
        #expect(WaveLine.lines(count: 4) == three + echoes.prefix(1))
        #expect(WaveLine.lines(count: 5) == three + echoes.prefix(2))
        #expect(WaveLine.lines(count: 6) == three + echoes)
        #expect(WaveLine.lines(count: 0) == [overall])
        #expect(WaveLine.lines(count: 7) == three + echoes)
        #expect(WaveAppearance.standard.lines == three)
    }

    @Test func lookTitlesAndDefault() throws {
        #expect(WaveLook.allCases == [.waves, .spectrum])
        #expect(WaveLook.allCases.map(\.title) == ["Волны", "Спектр"])
        #expect(WaveAppearance.standard.look == .waves)
        // Настройки 1.1 без поля стиля дают «Волны».
        let stored = Data(#"{"wingWidth": 120, "lineCount": 5}"#.utf8)
        #expect(try JSONDecoder().decode(WaveAppearance.self, from: stored).look == .waves)
    }

    /// Линии каждого стиля в крыле (свернутый остров) и в панели. У «Спектра» над линией призрак
    /// пика (`spectrumPeaks`, по умолчанию включен): прозрачность 0.35, толщина × 0.7, без
    /// свечения и без заливки.
    @Test func lookTable() {
        let overall = WaveLine(source: .overall, shape: .mid, phaseOffset: 0, amplitudeScale: 1, opacity: 1)
        let spectrum = WaveLine(source: .spectrum, shape: .mid, phaseOffset: 0, amplitudeScale: 1, opacity: 1)
        let ghost = WaveLine(
            source: .spectrumPeak, shape: .mid, phaseOffset: 0, amplitudeScale: 1, opacity: 0.35, widthScale: 0.7
        )
        #expect(WaveAppearance.standard.spectrumPeaks)
        for count in 1...6 {
            var appearance = WaveAppearance.standard
            appearance.lineCount = count
            for profile in WaveProfile.allCases {
                #expect(appearance.lines(for: profile) == WaveLine.lines(count: count))
            }
            #expect(appearance.lines == appearance.lines(for: .wing))
            appearance.look = .spectrum
            for profile in WaveProfile.allCases {
                #expect(appearance.lines(for: profile) == [spectrum, ghost])
            }
            appearance.spectrumPeaks = false
            for profile in WaveProfile.allCases {
                #expect(appearance.lines(for: profile) == [spectrum])
            }
            // «Волнам» призрак не нужен.
            appearance.look = .waves
            appearance.spectrumPeaks = true
            #expect(!appearance.lines.contains { $0.source == .spectrumPeak })
        }
        #expect(overall.glows && overall.fills && overall.widthScale == 1)
        #expect(spectrum.glows && spectrum.fills && spectrum.widthScale == 1)
        #expect(!ghost.glows && !ghost.fills)
        #expect(WaveLine.lines(count: 6).allSatisfy { $0.fills && $0.widthScale == 1 })
    }

    /// Призрак пика сохраняется; настройки 1.2 без поля дают его включенным, поле не того типа тоже.
    @Test func spectrumPeaksDecodesAndDefaultsOn() throws {
        var appearance = WaveAppearance.standard
        appearance.look = .spectrum
        appearance.spectrumPeaks = false
        let data = try JSONEncoder().encode(appearance)
        #expect(String(decoding: data, as: UTF8.self).contains("\"spectrumPeaks\":false"))
        #expect(try JSONDecoder().decode(WaveAppearance.self, from: data) == appearance)
        let old = Data(#"{"wingWidth": 120, "lineCount": 5, "look": "spectrum", "colorByBand": true}"#.utf8)
        let decoded = try JSONDecoder().decode(WaveAppearance.self, from: old)
        #expect(decoded.spectrumPeaks && decoded.look == .spectrum && decoded.lineCount == 5)
        let broken = Data(#"{"spectrumPeaks": "yes"}"#.utf8)
        #expect(try JSONDecoder().decode(WaveAppearance.self, from: broken).spectrumPeaks)
        let built = WaveAppearance(
            wingWidth: 64, colorMode: .artwork, glowSize: 1, lineCount: 3, fill: 0, thickness: 1, amplitude: 1,
            spectrumPeaks: false
        )
        #expect(!built.spectrumPeaks)
    }

    @Test func lookGeometryTable() {
        #expect(WaveLookGeometry.standard == WaveLookGeometry(baseline: .center, widthScale: 1))
        func geometry(_ look: WaveLook) -> WaveLookGeometry {
            var appearance = WaveAppearance.standard
            appearance.look = look
            return appearance.lookGeometry
        }
        #expect(geometry(.waves) == .standard)
        #expect(geometry(.spectrum) == WaveLookGeometry(baseline: .bottom, widthScale: 1))
    }

    /// Стиль из будущей сборки дает «Волны», остальные поля сохраняются.
    @Test func unknownLookFallsBackToWaves() throws {
        let appearance = WaveAppearance(
            wingWidth: 120, colorMode: .preset(.neon), glowSize: 2, lineCount: 5, fill: 0.4, thickness: 1.5,
            amplitude: 0.8, colorFlow: 0.3, colorByBand: true, look: .spectrum
        )
        let json = String(decoding: try JSONEncoder().encode(appearance), as: UTF8.self)
        #expect(json.contains("\"look\":\"spectrum\""))
        let stored = Data(json.replacingOccurrences(of: "\"spectrum\"", with: "\"laser\"").utf8)
        let decoded = try JSONDecoder().decode(WaveAppearance.self, from: stored)
        var expected = appearance
        expected.look = .waves
        #expect(decoded == expected)
        // Поле не того типа тоже дает «Волны».
        let broken = Data(#"{"look": 3, "lineCount": 2}"#.utf8)
        let fallback = try JSONDecoder().decode(WaveAppearance.self, from: broken)
        #expect(fallback.look == .waves && fallback.lineCount == 2)
    }

    /// Стили «Минимал» и «Пульс» из 1.2 убраны: сохраненное слово открывается как «Волны», и само по
    /// себе, и внутри вида, остальные поля вида сохраняются.
    @Test func removedStylesDecodeAsWaves() throws {
        for word in ["minimal", "pulse"] {
            let alone = Data("\"\(word)\"".utf8)
            #expect(try JSONDecoder().decode(WaveLook.self, from: alone) == .waves)
            let stored = Data("{\"look\": \"\(word)\", \"lineCount\": 5, \"fill\": 0.4}".utf8)
            let decoded = try JSONDecoder().decode(WaveAppearance.self, from: stored)
            #expect(decoded.look == .waves && decoded.lineCount == 5 && decoded.fill == 0.4)
        }
        for look in WaveLook.allCases {
            let data = try JSONEncoder().encode(look)
            #expect(try JSONDecoder().decode(WaveLook.self, from: data) == look)
        }
    }

    private func hue(_ lab: OKLab) -> Float {
        atan2(lab.b, lab.a) * 180 / .pi
    }

    /// Разница оттенков в градусах, -180...180.
    private func hueDelta(_ a: OKLab, _ b: OKLab) -> Float {
        var d = hue(a) - hue(b)
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    @Test func customPaletteTurnsHue() {
        for hex: UInt32 in [0x3A7BD5, 0xE0457B, 0x2E8B57, 0xFF0000] {
            let labs = WaveAppearance.customPalette(RGBColor(hex: hex)).map(\.oklab)
            #expect(labs.count == 3)
            #expect(abs(hueDelta(labs[1], labs[0]) - 25) <= 0.5, "\(hex): \(hueDelta(labs[1], labs[0]))")
            #expect(abs(hueDelta(labs[2], labs[0]) + 25) <= 0.5, "\(hex): \(hueDelta(labs[2], labs[0]))")
            #expect(labs.allSatisfy { $0.l >= 0.55 - 1e-4 })
        }
        let black = WaveAppearance.customPalette(RGBColor(hex: 0x000000)).map(\.oklab)
        #expect(black.allSatisfy { $0.l >= 0.55 - 1e-4 }, "\(black.map(\.l))")
        let gray = WaveAppearance.customPalette(RGBColor(hex: 0x808080)).map(\.oklab)
        #expect(gray.allSatisfy { $0.chroma < 1e-3 })
        let broken = WaveAppearance.customPalette(RGBColor(r: .nan, g: 0, b: 1))
        #expect(broken.count == 3 && broken.allSatisfy(\.isFinite))
    }

    /// Чистый синий после подъема светлоты выходит за гамму sRGB: все три цвета вписываются в
    /// нее, теряя насыщенность, но не оттенок.
    @Test func customPaletteFitsPureBlueIntoGamut() {
        let blue = RGBColor(hex: 0x0000FF)
        let colors = WaveAppearance.customPalette(blue)
        let lifted = OKLab(l: 0.55, a: blue.oklab.a, b: blue.oklab.b)
        #expect(!lifted.isInSRGBGamut)
        for color in colors {
            #expect([color.r, color.g, color.b].allSatisfy { $0 >= 0 && $0 <= 1 }, "\(color)")
            #expect(color.oklab.isInSRGBGamut, "\(color)")
            #expect(abs(color.oklab.l - 0.55) < 1e-3, "\(color.oklab)")
        }
        let labs = colors.map(\.oklab)
        #expect(abs(hueDelta(labs[0], blue.oklab)) <= 0.5, "\(hueDelta(labs[0], blue.oklab))")
        #expect(abs(hueDelta(labs[1], labs[0]) - 25) <= 0.5, "\(hueDelta(labs[1], labs[0]))")
        #expect(abs(hueDelta(labs[2], labs[0]) + 25) <= 0.5, "\(hueDelta(labs[2], labs[0]))")
        #expect(labs[0].chroma < blue.oklab.chroma)
    }

    @Test func presetsAreDistinct() {
        #expect(WavePreset.allCases.map(\.title) == [
            "Аврора", "Закат", "Океан", "Неон", "Огонь", "Моно",
            "Лаванда", "Мята", "Коралл", "Лес", "Янтарь", "Сакура", "Лед", "Песок", "Радуга",
        ])
        #expect(WavePreset.allCases.allSatisfy { !$0.title.contains("ё") && !$0.title.contains(" ") })
        for preset in WavePreset.allCases {
            let labs = preset.colors.map(\.oklab)
            #expect(labs.count == 3)
            for i in labs.indices {
                for j in labs.indices where j > i {
                    #expect(labs[i].distance(to: labs[j]) >= 0.08, "\(preset) \(i) \(j)")
                }
            }
        }
        #expect(Set(WavePreset.allCases.map { $0.colors.flatMap { [$0.r, $0.g, $0.b] } }).count == WavePreset.allCases.count)
        #expect(WavePreset.aurora.colors == [RGBColor(hex: 0x4BE3C1), RGBColor(hex: 0x5B8CFF), RGBColor(hex: 0xB06CFF)])
    }

    @Test func newPresetsAreBrightAndDistinct() {
        let newPresets: [WavePreset] = [.lavender, .mint, .coral, .forest, .amber, .sakura, .ice, .sand, .rainbow]
        #expect(Array(WavePreset.allCases.suffix(9)) == newPresets)
        for preset in newPresets {
            let labs = preset.colors.map(\.oklab)
            #expect(labs.count == 3)
            for lab in labs {
                #expect(lab.l >= PaletteExtractor.liftedLightness, "\(preset) \(lab.l)")
            }
            for i in labs.indices {
                for j in labs.indices where j > i {
                    #expect(labs[i].distance(to: labs[j]) >= 0.08, "\(preset) \(i) \(j)")
                }
            }
        }
        #expect(WavePreset.lavender.colors == [RGBColor(hex: 0xB79CFF), RGBColor(hex: 0xF0A6E8), RGBColor(hex: 0x6F9BFF)])
    }

    @Test func newPresetsDecode() throws {
        let one = try JSONEncoder().encode(WaveColorMode.preset(.lavender))
        #expect(String(decoding: one, as: UTF8.self) == "{\"preset\":{\"_0\":\"lavender\"}}")
        let stored = Data("{\"preset\":{\"_0\":\"lavender\"}}".utf8)
        #expect(try JSONDecoder().decode(WaveColorMode.self, from: stored) == .preset(.lavender))
    }

    @Test func paletteFollowsMode() {
        let artwork = [RGBColor(hex: 0x112233), RGBColor(hex: 0x445566), RGBColor(hex: 0x778899)]
        var appearance = WaveAppearance.standard
        #expect(appearance.palette(artwork: artwork) == artwork)
        appearance.colorMode = .preset(.fire)
        #expect(appearance.palette(artwork: artwork) == WavePreset.fire.colors)
        let custom = RGBColor(hex: 0x3A7BD5)
        appearance.colorMode = .custom(custom)
        #expect(appearance.palette(artwork: artwork) == WaveAppearance.customPalette(custom))
    }
}
