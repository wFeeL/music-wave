import Foundation
import Testing
@testable import WaveCore

struct WaveAppearanceTests {
    @Test func defaultsMatchSpec() {
        #expect(WaveAppearance.standard == WaveAppearance(
            wingWidth: 64, colorMode: .artwork, glowRadius: 1, lineCount: 3, fill: 0, thickness: 1, amplitude: 1
        ))
        #expect(WaveAppearance.Limits.wingWidth == 40...200)
        #expect(WaveAppearance.Limits.glowRadius == 0.5...3)
        #expect(WaveAppearance.Limits.lineCount == 1...6)
        #expect(WaveAppearance.Limits.fill == 0...1)
        #expect(WaveAppearance.Limits.thickness == 0.5...2)
        #expect(WaveAppearance.Limits.amplitude == 0.5...2)
    }

    @Test func clampsRanges() {
        let high = WaveAppearance(
            wingWidth: 300, colorMode: .artwork, glowRadius: 5, lineCount: 9, fill: 2, thickness: 3, amplitude: 9
        )
        #expect(high.wingWidth == 200 && high.glowRadius == 3 && high.lineCount == 6)
        #expect(high.fill == 1 && high.thickness == 2 && high.amplitude == 2)
        let low = WaveAppearance(
            wingWidth: 10, colorMode: .artwork, glowRadius: 0, lineCount: 0, fill: -1, thickness: .nan, amplitude: -.infinity
        )
        #expect(low.wingWidth == 40 && low.glowRadius == 0.5 && low.lineCount == 1)
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
                wingWidth: 180, colorMode: .custom(RGBColor(hex: 0x123456)), glowRadius: 2.5,
                lineCount: 6, fill: 0.7, thickness: 1.5, amplitude: 0.5
            ),
            WaveAppearance(wingWidth: 40, colorMode: .preset(.neon), glowRadius: 0.5, lineCount: 1, fill: 1, thickness: 2, amplitude: 2),
        ]
        for appearance in samples {
            let data = try JSONEncoder().encode(appearance)
            #expect(try JSONDecoder().decode(WaveAppearance.self, from: data) == appearance)
        }
        // Значения вне диапазона и пропущенные поля при чтении приводятся к допустимым.
        let stored = Data(#"{"wingWidth": 900, "lineCount": 4}"#.utf8)
        let decoded = try JSONDecoder().decode(WaveAppearance.self, from: stored)
        #expect(decoded.wingWidth == 200 && decoded.lineCount == 4)
        #expect(decoded.colorMode == .artwork && decoded.glowRadius == 1 && decoded.fill == 0)
    }

    /// Неизвестная готовая палитра дает «Из обложки», остальные поля сохраняются.
    @Test func unknownPresetFallsBackToArtwork() throws {
        let appearance = WaveAppearance(
            wingWidth: 120, colorMode: .preset(.neon), glowRadius: 2, lineCount: 5, fill: 0.4, thickness: 1.5, amplitude: 0.8
        )
        let json = String(decoding: try JSONEncoder().encode(appearance), as: UTF8.self)
        #expect(json.contains("\"neon\""))
        let stored = Data(json.replacingOccurrences(of: "\"neon\"", with: "\"rainbow\"").utf8)
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
        #expect(decoded.glowRadius == WaveAppearance.standard.glowRadius)
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
        #expect(WavePreset.allCases.map(\.title) == ["Аврора", "Закат", "Океан", "Неон", "Огонь", "Моно"])
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
