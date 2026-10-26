import AppKit
import ImageIO
import Synchronization
import Testing
import WaveCore
@testable import WaveFeels

@MainActor
struct SnapshotRendererTests {
    static let names = [
        "01-silent", "02-loud-beat", "03-loud-no-beat", "04-expanded", "05-expanded-paused",
        "06-long-title", "07-palette-warm", "08-palette-cold", "09-pill-external",
        "10-expanded-no-artwork", "11-expanded-no-adapter", "12-pill-expanded",
        "13-settings", "13-settings-dark", "13-settings-tall", "13-settings-appearance", "13-settings-appearance-dark",
        "14-wings-wide", "15-preset-aurora", "15-preset-sunset", "15-preset-ocean", "15-preset-neon",
        "15-preset-fire", "15-preset-mono", "16-custom-color", "17-fill-thick-tall", "17-fill-normal", "18-one-line",
        "18-six-lines", "19-glow-radius-3x", "21-banner", "21-banner-light", "21-banner-long-title",
        "21-banner-pill", "21-banner-no-artwork", "21-banner-wide-wings",
        "13-settings-appearance-tall", "13-settings-features", "13-settings-features-dark",
        "22-style-spectrum", "22-style-minimal", "22-style-pulse", "22-style-pulse-pill",
        "22-style-spectrum-expanded", "22-style-pulse-expanded", "23-color-by-band", "23-color-by-band-spectrum",
        "23-color-flow", "24-progress-line", "24-progress-line-pill", "25-artwork-glow", "26-high-contrast",
        "26-reduce-transparency", "05-expanded-stale-progress",
    ]

    /// Раскрытые панели сцен 1.2: обложка и кнопки на тех же местах, что в 1.1.
    static let expandedFeatureNames = [
        "05-expanded-stale-progress", "22-style-spectrum-expanded", "22-style-pulse-expanded", "25-artwork-glow",
        "26-reduce-transparency",
    ]

    /// Вкладки «Вид» и «Функции» снимаются светлыми и темными, «Вид» еще и в самом высоком
    /// состоянии, прежние снимки «Основных» на месте.
    @Test func settingsScenesIncludeAppearanceTab() {
        let scenes = SnapshotRenderer.settingsScenes
        let names = scenes.map(\.name)
        #expect(names.contains("13-settings-appearance"))
        #expect(names.contains("13-settings-appearance-dark"))
        #expect(scenes.filter { $0.tab == .appearance }.map(\.name) == [
            "13-settings-appearance", "13-settings-appearance-dark", "13-settings-appearance-tall",
        ])
        #expect(scenes.filter { $0.tab == .general }.map(\.name) == ["13-settings", "13-settings-dark", "13-settings-tall"])
        #expect(scenes.filter { $0.tab == .features }.map(\.name) == ["13-settings-features", "13-settings-features-dark"])
        #expect(scenes.first { $0.name == "13-settings-appearance-dark" }?.dark == true)
        #expect(scenes.first { $0.name == "13-settings-appearance-tall" }?.tall == true)
        #expect(scenes.first { $0.name == "13-settings-features-dark" }?.dark == true)
    }

    /// Самый высокий «Вид» показывает все необязательные строки: «Свой цвет», строку о нагрузке
    /// и подпись под крылом. Стиль «Волны» (все строки линий, без подписи «Пульса», которая
    /// зависит от «Уменьшения движения» машины).
    @Test func tallAppearanceShowsEveryOptionalRow() {
        let appearance = SnapshotRenderer.tallAppearance
        #expect(appearance.look == .waves)
        var custom = false
        if case .custom = appearance.colorMode {
            custom = true
        }
        #expect(custom)
        #expect(AppearanceSettingsView.costHint(for: appearance) != nil)
        let caption = AppearanceSettingsView.wingCaption(
            wing: appearance.wingWidth, limit: SnapshotRenderer.tallWingLimit, hasNotch: true
        )
        #expect(caption == "ограничено до 160 pt")
    }

    @Test func rendersAllSnapshotsWithVisibleWaves() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavefeels-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Сторож меряет, сколько главный поток был занят без перерыва, пока идет тест: соседние
        // тесты на главном акторе ждут ровно столько.
        let clock = ContinuousClock()
        let watch = MainThreadWatch()
        watch.start()
        defer { _ = watch.stop() }
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
        // текст, стиль, свечение обложки и скрытая полоса прогресса не сдвигают ее, середина
        // обложки цветная, не черная.
        let artwork = SnapshotRenderer.artworkSampleRect()
        let artworkArea = Int(artwork.width * artwork.height * SnapshotRenderer.scale * SnapshotRenderer.scale)
        for name in ["04-expanded", "05-expanded-paused", "06-long-title"] + Self.expandedFeatureNames {
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
        for name in ["04-expanded", "05-expanded-paused", "06-long-title", "10-expanded-no-artwork"] + Self.expandedFeatureNames {
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
        // Баннер: белое название под вырезом на своем месте, на капсуле тоже.
        for (name, pill) in [
            ("21-banner", false), ("21-banner-light", false), ("21-banner-long-title", false),
            ("21-banner-no-artwork", false), ("21-banner-wide-wings", false), ("21-banner-pill", true),
        ] {
            let banner = try Bitmap(url: directory.appendingPathComponent("\(name).png"))
            let text = SnapshotRenderer.bannerTextSampleRect(pill: pill)
            let bright = banner.brightPixels(in: text, scale: SnapshotRenderer.scale)
            #expect(bright > 100, "\(name): светлых пикселей в названии \(bright)")
        }

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

        // Снимки настроек непрозрачны (переключатель вкладок сведен на фон окна), и вкладки
        // читаются: в темном оформлении светлый текст, в светлом темный. Полоса шириной во все
        // три вкладки («Основные», «Вид», «Функции»).
        let tabBar = CGRect(x: settingsSize.width / 2 - 130, y: 0, width: 260, height: 24)
        for name in SnapshotRenderer.settingsScenes.map(\.name) {
            let bitmap = try Bitmap(url: directory.appendingPathComponent("\(name).png"))
            let scale = CGFloat(bitmap.width) / settingsSize.width
            let translucent = bitmap.translucentPixels(in: settingsRect, scale: scale)
            #expect(translucent == 0, "\(name): полупрозрачных пикселей \(translucent)")
            let isDark = SnapshotRenderer.settingsScenes.first { $0.name == name }?.dark ?? false
            let text = isDark
                ? bitmap.brightPixels(in: tabBar, scale: scale)
                : bitmap.darkPixels(in: tabBar, scale: scale)
            #expect(text > Int(20 * scale * scale), "\(name): пикселей текста вкладок \(text)")
        }

        let longest = watch.stop()
        print("SnapshotRendererTests: renderAll \(rendered), whole test \(clock.now - started), longest main thread hold \(longest)")
        // Соседние тесты ждут главный актор со своими сроками, поэтому отрисовка отпускает его между
        // снимками. Цель меньше 1 с, фактическое время в логе; предел с запасом на загруженный
        // виртуальный мак.
        #expect(longest < .seconds(5), "главный поток занят без перерыва \(longest)")

        // Предпросмотр вкладки «Вид» рисует волны: снимок с демо против того же окна без демо.
        // Все, кроме острова в полосе предпросмотра, у них одинаковое.
        let seeded = PreviewTimelineCache.shared.timeline
        #expect(seeded != nil, "renderAll не отдал демо предпросмотру")
        let suite = "com.wfeels.wavefeels.tests.preview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let control = AppModel(defaults: defaults)
        PreviewTimelineCache.shared.timeline = nil
        defer { PreviewTimelineCache.shared.timeline = seeded }
        for scene in SnapshotRenderer.settingsScenes where scene.tab == .appearance {
            let unseeded = directory.appendingPathComponent("\(scene.name)-unseeded.png")
            try SnapshotRenderer.renderSettings(
                name: scene.name, dark: scene.dark, tall: scene.tall, tab: .appearance, model: control, to: unseeded
            )
            let shot = try Bitmap(url: directory.appendingPathComponent("\(scene.name).png"))
            let silent = try Bitmap(url: unseeded)
            let scale = CGFloat(shot.width) / settingsSize.width
            let waves = shot.saturatedPixels(in: settingsRect, scale: scale)
            let quiet = silent.saturatedPixels(in: settingsRect, scale: scale)
            #expect(waves - quiet > Int(40 * scale * scale), "\(scene.name): цветных пикселей \(waves), без демо \(quiet)")
            await Task.yield()
        }
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

/// Сторож главного потока: таймер на главной очереди dispatch тикает каждые 20 мс, самый большой
/// разрыв между тиками (за вычетом шага) и есть самое долгое непрерывное занятие главного потока.
/// Задача с `Task.sleep` для этого не годится: ее продолжение сначала ждет поток общего пула и
/// показывает еще и его загрузку.
private final class MainThreadWatch: @unchecked Sendable {
    private static let step: Duration = .milliseconds(20)

    private struct State {
        var last: ContinuousClock.Instant?
        var longest: Duration = .zero
    }

    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private let state = Mutex(State())

    func start() {
        timer.setEventHandler { [self] in
            let now = ContinuousClock.now
            state.withLock { value in
                if let last = value.last {
                    value.longest = max(value.longest, now - last - Self.step)
                }
                value.last = now
            }
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.resume()
    }

    /// Останавливает таймер и возвращает самый большой разрыв. Повторный вызов безопасен.
    func stop() -> Duration {
        if !timer.isCancelled {
            timer.cancel()
        }
        return state.withLock { $0.longest }
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

    /// Сколько пикселей в `rect` (pt, начало сверху слева) не полностью непрозрачны.
    func translucentPixels(in rect: CGRect, scale: CGFloat) -> Int {
        let x0 = max(Int((rect.minX * scale).rounded(.down)), 0)
        let x1 = min(Int((rect.maxX * scale).rounded(.up)), width)
        let y0 = max(Int((rect.minY * scale).rounded(.down)), 0)
        let y1 = min(Int((rect.maxY * scale).rounded(.up)), height)
        var count = 0
        for y in y0..<max(y1, y0) {
            for x in x0..<max(x1, x0) where pixels[(y * width + x) * 4 + 3] < 255 {
                count += 1
            }
        }
        return count
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
