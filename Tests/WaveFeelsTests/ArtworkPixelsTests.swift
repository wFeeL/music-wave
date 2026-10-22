import CoreGraphics
import Foundation
import ImageIO
import Testing
import WaveCore
@testable import WaveFeels

struct ArtworkPixelsTests {
    @Test func solidPNGShrinksTo64AndKeepsColor() throws {
        let data = try Self.solidPNG(side: 300, red: 200, green: 80, blue: 40)
        let result = try #require(ArtworkPixels.rgba64(from: data))
        #expect(result.width == 64)
        #expect(result.height == 64)
        #expect(result.pixels.count == 64 * 64 * 4)

        var worst = 0
        for offset in stride(from: 0, to: result.pixels.count, by: 4) {
            let pixel = result.pixels[offset..<offset + 4].map(Int.init)
            worst = max(worst, abs(pixel[0] - 200), abs(pixel[1] - 80), abs(pixel[2] - 40), abs(pixel[3] - 255))
        }
        #expect(worst <= 2, "наибольшее отклонение канала \(worst)")
    }

    @Test func garbageGivesNil() {
        let garbage = Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        #expect(ArtworkPixels.rgba64(from: garbage)?.width == nil)
        #expect(ArtworkPixels.rgba64(from: Data())?.width == nil)
    }

    @Test func analysisOfSolidArtworkGivesImageAndThreeColors() throws {
        let data = try Self.solidPNG(side: 300, red: 40, green: 90, blue: 220)
        let analysis = ArtworkAnalysis(data: data, displayPixels: 144)
        let image = try #require(analysis.image)
        #expect(max(image.width, image.height) <= 144)
        #expect(analysis.palette.count == 3)
        #expect(analysis.palette != PaletteExtractor.fallback)

        let broken = ArtworkAnalysis(data: Data([1, 2, 3]), displayPixels: 144)
        #expect(broken.image == nil)
        #expect(broken.palette == PaletteExtractor.fallback)
    }

    @Test func snapshotArtworkGivesItsOwnPalette() throws {
        let pixels = try #require(ArtworkPixels.rgba64(from: SnapshotRenderer.testArtwork))
        let palette = PaletteExtractor.extract(rgba: pixels.pixels, width: pixels.width, height: pixels.height)
        #expect(palette.count == 3)
        #expect(palette != PaletteExtractor.fallback)
    }

    /// PNG `side`×`side` одного цвета в sRGB.
    private static func solidPNG(side: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
