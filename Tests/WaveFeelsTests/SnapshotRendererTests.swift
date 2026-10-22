import AppKit
import ImageIO
import Testing
@testable import WaveFeels

@MainActor
struct SnapshotRendererTests {
    static let names = [
        "01-silent", "02-loud-beat", "03-loud-no-beat", "04-expanded", "05-expanded-paused",
        "06-long-title", "07-palette-warm", "08-palette-cold", "09-pill-external",
    ]

    @Test func rendersAllSnapshotsWithVisibleWaves() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavefeels-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = try SnapshotRenderer.renderAll(to: directory, demo: Self.demo)
        let writtenNames = Set(written.map { $0.deletingPathExtension().lastPathComponent })
        for name in Self.names {
            let url = directory.appendingPathComponent("\(name).png")
            #expect(writtenNames.contains(name), "\(name) не в списке")
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
            #expect(size > 2048, "\(name): \(size) байт")
        }

        let manifest = try String(
            contentsOf: directory.appendingPathComponent(SnapshotRenderer.manifestName), encoding: .utf8
        )
        let listed = manifest.split(separator: "\n").map(String.init)
        #expect(listed == written.map(\.lastPathComponent))
        #expect(listed.count >= Self.names.count)

        let wings = SnapshotRenderer.wingSampleRects()
        let loud = try Bitmap(url: directory.appendingPathComponent("02-loud-beat.png"))
        let silent = try Bitmap(url: directory.appendingPathComponent("01-silent.png"))
        #expect(loud.width == Int(SnapshotRenderer.screenSize.width * SnapshotRenderer.scale))
        let loudCount = wings.map { loud.saturatedPixels(in: $0, scale: SnapshotRenderer.scale) }.reduce(0, +)
        let silentCount = wings.map { silent.saturatedPixels(in: $0, scale: SnapshotRenderer.scale) }.reduce(0, +)
        #expect(loudCount > 100, "02-loud-beat: насыщенных пикселей в крыльях \(loudCount)")
        #expect(silentCount == 0, "01-silent: насыщенных пикселей в крыльях \(silentCount)")
    }

    /// `Resources/Demo/demo.wav` в корне репозитория.
    private static var demo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Demo/demo.wav")
    }
}

/// PNG, перерисованный в RGBA 8 бит sRGB, строки сверху вниз.
private struct Bitmap {
    /// Насыщенность (HSV) выше этого порога считается цветом.
    static let saturationThreshold = 0.3
    /// Тусклые пиксели не в счет: у почти черных насыщенность неустойчива, а линия в тишине
    /// намеренно сохраняет оттенок обложки при яркости около 6 %. Видимая волна намного ярче.
    static let minimumValue = 64

    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CocoaError(.fileReadCorruptFile) }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Сколько пикселей в `rect` (pt, начало сверху слева) с насыщенностью выше порога.
    func saturatedPixels(in rect: CGRect, scale: CGFloat) -> Int {
        let x0 = max(Int((rect.minX * scale).rounded(.down)), 0)
        let x1 = min(Int((rect.maxX * scale).rounded(.up)), width)
        let y0 = max(Int((rect.minY * scale).rounded(.down)), 0)
        let y1 = min(Int((rect.maxY * scale).rounded(.up)), height)
        var count = 0
        for y in y0..<max(y1, y0) {
            for x in x0..<max(x1, x0) {
                let offset = (y * width + x) * 4
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                let high = max(r, g, b), low = min(r, g, b)
                guard high >= Self.minimumValue else { continue }
                if Double(high - low) / Double(high) > Self.saturationThreshold {
                    count += 1
                }
            }
        }
        return count
    }
}
