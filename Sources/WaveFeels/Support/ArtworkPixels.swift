import CoreGraphics
import Foundation
import ImageIO
import WaveCore

/// Обложка из Now Playing (PNG, JPEG и все, что читает ImageIO): уменьшенная картинка для
/// панели и пиксели 64×64 для `PaletteExtractor`. Большие обложки декодируются сразу в
/// уменьшенном виде (`CGImageSourceCreateThumbnailAtIndex`), без полного растра.
enum ArtworkPixels {
    /// Сторона растра для палитры.
    static let side = 64

    /// RGBA 64×64, 8 бит на канал, sRGB, `premultipliedLast`, строки подряд сверху вниз.
    /// `nil`, если данные не картинка.
    static func rgba64(from data: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let image = image(from: data, maxPixelSize: side * 2) else { return nil }
        return rgba64(from: image)
    }

    /// Та же картинка, перерисованная в 64×64. Пропорции не сохраняются: для палитры важны
    /// только доли цветов.
    static func rgba64(from image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = Self.side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? (pixels, side, side) : nil
    }

    /// Картинка не больше `maxPixelSize` пикселей по большей стороне (меньшая не увеличивается),
    /// с поворотом из EXIF. `nil`, если данные не картинка.
    static func image(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard !data.isEmpty, maxPixelSize > 0 else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Обложка, разобранная вне главного актора: картинка для панели и палитра волн. Без картинки
/// палитра стандартная. `CGImage` неизменяемый и потокобезопасный, поэтому значение можно
/// передать между акторами.
struct ArtworkAnalysis: @unchecked Sendable {
    let image: CGImage?
    let palette: [PaletteColor]

    /// `displayPixels`: сторона картинки для панели в пикселях. Палитра считается по ней же,
    /// поэтому данные декодируются один раз.
    init(data: Data, displayPixels: Int) {
        let image = ArtworkPixels.image(from: data, maxPixelSize: displayPixels)
        self.image = image
        if let image, let raster = ArtworkPixels.rgba64(from: image) {
            palette = PaletteExtractor.extract(rgba: raster.pixels, width: raster.width, height: raster.height)
        } else {
            palette = PaletteExtractor.fallback
        }
    }
}
