import AppKit
import ImageIO
import Testing
@testable import WaveFeels

@MainActor
struct SnapshotRendererTests {
    static let names = [
        "01-silent", "02-loud-beat", "03-loud-no-beat", "04-expanded", "05-expanded-paused",
        "06-long-title", "07-palette-warm", "08-palette-cold", "09-pill-external",
        "10-expanded-no-artwork", "11-expanded-no-adapter", "12-pill-expanded",
        "13-settings", "13-settings-dark", "13-settings-tall",
    ]

    /// Шаг сердцебиения, которым тест меряет, надолго ли отрисовка занимает главный актор.
    static let heartbeat: Duration = .milliseconds(20)

    @Test func rendersAllSnapshotsWithVisibleWaves() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavefeels-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Пока идет отрисовка, задача на главном акторе просыпается каждые 20 мс; самый большой
        // разрыв между пробуждениями показывает, сколько главный актор был занят без перерыва.
        // Соседние тесты на главном акторе (таймеры адаптера и конвейера) ждут ровно столько.
        let clock = ContinuousClock()
        let watch = Task { @MainActor in
            var longest = Duration.zero
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeat)
                let now = clock.now
                longest = max(longest, now - last - Self.heartbeat)
                last = now
            }
            return longest
        }
        defer { watch.cancel() }
        let started = clock.now
        let written = try await SnapshotRenderer.renderAll(to: directory, demo: Self.demo)
        let rendered = clock.now - started
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

        await Task.yield()
        // Раскрытая панель показывает обложку (или градиент вместо нее) на своем месте: длинный
        // текст не сдвигает ее, середина обложки цветная, не черная.
        let artwork = SnapshotRenderer.artworkSampleRect()
        let artworkArea = Int(artwork.width * artwork.height * SnapshotRenderer.scale * SnapshotRenderer.scale)
        for name in ["04-expanded", "05-expanded-paused", "06-long-title"] {
            let expanded = try Bitmap(url: directory.appendingPathComponent("\(name).png"))
            let artworkCount = expanded.saturatedPixels(in: artwork, scale: SnapshotRenderer.scale)
            #expect(artworkCount > artworkArea / 2, "\(name): цветных пикселей обложки \(artworkCount) из \(artworkArea)")
        }

        await Task.yield()
        // Плитка без обложки и значок источника не цветные, но и не пустые.
        for name in ["10-expanded-no-artwork", "11-expanded-no-adapter"] {
            let expanded = try Bitmap(url: directory.appendingPathComponent("\(name).png"))
            let visible = expanded.visiblePixels(in: artwork, scale: SnapshotRenderer.scale)
            #expect(visible > artworkArea / 4, "\(name): заметных пикселей на месте обложки \(visible) из \(artworkArea)")
        }

        await Task.yield()
        // Кнопки на своем месте: в середине средней кнопки белый значок «пауза» или «играть».
        let transport = SnapshotRenderer.transportSampleRects()
        for name in ["04-expanded", "05-expanded-paused", "06-long-title", "10-expanded-no-artwork"] {
            let expanded = try Bitmap(url: directory.appendingPathComponent("\(name).png"))
            let bright = expanded.brightPixels(in: transport.play, scale: SnapshotRenderer.scale)
            #expect(bright > 100, "\(name): светлых пикселей в кнопке «пауза/играть» \(bright)")
            let back = expanded.brightPixels(in: transport.backward, scale: SnapshotRenderer.scale)
            #expect(back > 20, "\(name): светлых пикселей в кнопке «назад» \(back)")
        }
        // Без Now Playing кнопок управления нет (кнопка «Открыть» правее, на месте «пауза/играть»).
        let noAdapter = try Bitmap(url: directory.appendingPathComponent("11-expanded-no-adapter.png"))
        #expect(noAdapter.brightPixels(in: transport.backward, scale: SnapshotRenderer.scale) == 0)

        await Task.yield()
        // Окно настроек отрисовано целиком, а не пустым фоном: в светлом оформлении есть темный
        // текст, в темном светлый. Масштаб зависит от экрана, на котором идет отрисовка.
        let settingsSize = SettingsView.windowSize
        let settingsRect = CGRect(origin: .zero, size: settingsSize)
        let light = try Bitmap(url: directory.appendingPathComponent("13-settings.png"))
        let dark = try Bitmap(url: directory.appendingPathComponent("13-settings-dark.png"))
        for (name, bitmap) in [("13-settings", light), ("13-settings-dark", dark)] {
            #expect(bitmap.width >= Int(settingsSize.width), "\(name): ширина \(bitmap.width)")
        }
        let lightScale = CGFloat(light.width) / settingsSize.width
        let darkScale = CGFloat(dark.width) / settingsSize.width
        let ink = light.darkPixels(in: settingsRect, scale: lightScale)
        let glyphs = dark.brightPixels(in: settingsRect, scale: darkScale)
        #expect(ink > 2000, "13-settings: темных пикселей \(ink)")
        #expect(glyphs > 2000, "13-settings-dark: светлых пикселей \(glyphs)")

        watch.cancel()
        let longest = await watch.value
        print("SnapshotRendererTests: renderAll \(rendered), whole test \(clock.now - started), longest main actor hold \(longest)")
        // Соседние тесты ждут главный актор со своими сроками, поэтому отрисовка отпускает его между
        // снимками. Цель меньше 1 с, фактическое время в логе; предел с запасом на загруженный
        // виртуальный мак.
        #expect(longest < .seconds(5), "главный актор занят без перерыва \(longest)")
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

    /// Почти белые пиксели: все каналы от этого значения.
    static let brightValue: UInt8 = 200

    /// Сколько пикселей в `rect` (pt, начало сверху слева) заметно светлее черного.
    func visiblePixels(in rect: CGRect, scale: CGFloat) -> Int {
        count(in: rect, scale: scale) { r, g, b in max(r, g, b) >= 20 }
    }

    /// Сколько почти черных пикселей в `rect` (pt, начало сверху слева).
    func darkPixels(in rect: CGRect, scale: CGFloat) -> Int {
        count(in: rect, scale: scale) { r, g, b in max(r, g, b) <= 60 }
    }

    /// Сколько почти белых пикселей в `rect` (pt, начало сверху слева).
    func brightPixels(in rect: CGRect, scale: CGFloat) -> Int {
        count(in: rect, scale: scale) { r, g, b in min(r, g, b) >= Self.brightValue }
    }

    private func count(in rect: CGRect, scale: CGFloat, where matches: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        let x0 = max(Int((rect.minX * scale).rounded(.down)), 0)
        let x1 = min(Int((rect.maxX * scale).rounded(.up)), width)
        let y0 = max(Int((rect.minY * scale).rounded(.down)), 0)
        let y1 = min(Int((rect.maxY * scale).rounded(.up)), height)
        var count = 0
        for y in y0..<max(y1, y0) {
            for x in x0..<max(x1, x0) {
                let offset = (y * width + x) * 4
                if matches(pixels[offset], pixels[offset + 1], pixels[offset + 2]) {
                    count += 1
                }
            }
        }
        return count
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
