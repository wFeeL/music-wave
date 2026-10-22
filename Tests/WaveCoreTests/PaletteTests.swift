import Foundation
import Testing
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
        #expect(mixPalettes(a, b, t: -3) == mixPalettes(a, b, t: 0))
        #expect(mixPalettes(a, b, t: 9) == mixPalettes(a, b, t: 1))
    }
}
