import AppKit
import ImageIO
import SwiftUI
import WaveCore

enum SnapshotError: Error, CustomStringConvertible {
    case demoNotFound
    case renderFailed(String)
    case encodeFailed(String)

    var description: String {
        switch self {
        case .demoNotFound: "нет Demo/demo.wav в ресурсах приложения"
        case .renderFailed(let name): "не отрисован снимок \(name)"
        case .encodeFailed(let name): "не удалось записать PNG \(name)"
        }
    }
}

/// Снимки острова для CI: PNG в масштабе 2 на фоне строки меню macOS. После них снимки окна
/// настроек в размере настоящего окна: светлый, темный и самый высокий (ручная задержка и
/// подсказка о доступе к звуку), на котором видно, если содержимое не помещается.
///
/// Кадры анализа не задаются руками: `demo.wav` прогоняется через `Analyzer` вне реального
/// времени с шагом 1/60 с до нужного момента, вместе с ним двигаются фазы волн и «вздох».
/// Тишина получается так же: после 6 с звук обнуляется, и волны затихают 2 с.
enum SnapshotRenderer {
    static let scale: CGFloat = 2
    /// Размер экрана снимка, pt.
    static let screenSize = CGSize(width: 760, height: 236)
    static let notchSize = CGSize(width: 185, height: 32)
    /// Строка меню внешнего монитора без выреза.
    static let externalMenuBarHeight: CGFloat = 24

    static let warmPalette = [PaletteColor(hex: 0xFF8A3D), PaletteColor(hex: 0xFFC857), PaletteColor(hex: 0xF2545B)]
    static let coldPalette = [PaletteColor(hex: 0x3D8BFF), PaletteColor(hex: 0x5EEAD4), PaletteColor(hex: 0xA78BFA)]

    /// Источник снимков: Яндекс Музыка, как у владельца.
    static let source = AudioSource.application(
        bundleID: "ru.yandex.desktop.music",
        bundlePath: "/Applications/Яндекс Музыка.app",
        displayName: "Яндекс Музыка"
    )

    static let track = NowPlayingInfo(
        bundleIdentifier: "ru.yandex.desktop.music",
        title: "Ночной город",
        artist: "Синтетика",
        isPlaying: true,
        duration: 214,
        elapsedTime: 63,
        artworkData: testArtwork
    )
    static let longTitleTrack = NowPlayingInfo(
        bundleIdentifier: "ru.yandex.desktop.music",
        title: "Очень длинное название трека, которое не помещается целиком",
        artist: "Полина Северная",
        isPlaying: true,
        duration: 377,
        elapsedTime: 141,
        artworkData: testArtwork
    )

    /// Тестовая обложка 300×300 PNG: плавный диагональный градиент индиго, малинового и янтарного
    /// с бирюзовым пятном в нижнем левом углу. Проходит тот же путь, что настоящая обложка:
    /// ImageIO, `ArtworkPixels`, `PaletteExtractor`.
    static let testArtwork: Data = makeTestArtwork()

    private static func makeTestArtwork() -> Data {
        let side = 300
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return Data() }
        func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
            CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
            )
        }
        let size = CGFloat(side)
        // CGContext: начало снизу слева. Индиго сверху слева, янтарный снизу справа.
        if let diagonal = CGGradient(
            colorsSpace: space,
            colors: [color(0x2E2A8C), color(0xB83A7A), color(0xF2A65A)] as CFArray,
            locations: [0, 0.55, 1]
        ) {
            context.drawLinearGradient(
                diagonal, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: []
            )
        }
        if let glow = CGGradient(
            colorsSpace: space,
            colors: [color(0x2EC4B6, alpha: 0.85), color(0x2EC4B6, alpha: 0)] as CFArray,
            locations: [0, 1]
        ) {
            let center = CGPoint(x: size * 0.18, y: size * 0.2)
            context.drawRadialGradient(
                glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: size * 0.55, options: []
            )
        }
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : Data()
    }

    /// Экран со встроенным вырезом по центру.
    static var notchLayout: NotchLayout {
        let side = (screenSize.width - notchSize.width) / 2
        let screen = ScreenDescriptor(
            id: 1, frame: CGRect(origin: .zero, size: screenSize), safeAreaTop: notchSize.height,
            auxiliaryLeftWidth: side, auxiliaryRightWidth: side, isBuiltIn: true, menuBarHeight: notchSize.height
        )
        return NotchGeometry.layout(for: [screen])!
    }

    /// Снимки окна настроек: имя, темное ли оформление и самое ли высокое состояние.
    static let settingsScenes: [(name: String, dark: Bool, tall: Bool)] = [
        ("13-settings", false, false),
        ("13-settings-dark", true, false),
        ("13-settings-tall", false, true),
    ]

    /// Внешний монитор без выреза: капсула под строкой меню.
    static var pillLayout: NotchLayout {
        let screen = ScreenDescriptor(
            id: 2, frame: CGRect(origin: .zero, size: screenSize), safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false, menuBarHeight: externalMenuBarHeight
        )
        return NotchGeometry.layout(for: [screen])!
    }

    /// Участки крыльев свернутого острова на снимке (pt, начало сверху слева), с запасом
    /// от краев формы и выреза: здесь видны только волны на черном.
    @MainActor
    static func wingSampleRects() -> [CGRect] {
        let layout = notchLayout
        let notch = layout.notch
        let island = layout.collapsedIsland(wingWidth: AppSettings.Default.wingWidth)
        let top = screenSize.height - island.maxY + 4
        let height = island.height - 8
        let width = notch.minX - island.minX - IslandGeometry.shoulderRadius - 8
        return [
            CGRect(x: notch.minX - width - 2, y: top, width: width, height: height),
            CGRect(x: notch.maxX + 2, y: top, width: width, height: height),
        ]
    }

    /// Середина обложки раскрытой панели на снимке (pt, начало сверху слева), с запасом 12 pt
    /// от краев обложки.
    @MainActor
    static func artworkSampleRect() -> CGRect {
        let (geometry, origin) = expandedGeometry()
        let content = geometry.panelContent
        let size = ExpandedPanelView.artworkSize
        let artwork = CGRect(
            x: origin.x + content.minX + geometry.panelInset, y: origin.y + content.minY, width: size, height: size
        )
        return artwork.insetBy(dx: 12, dy: 12)
    }

    /// Квадраты по центру кнопок «назад» (12×12 pt) и «пауза/играть» (20×20 pt) раскрытой панели
    /// на снимке. Рамка кнопок заходит за линию содержимого на поле значка «вперед».
    @MainActor
    static func transportSampleRects() -> (backward: CGRect, play: CGRect) {
        let (geometry, origin) = expandedGeometry()
        let content = geometry.panelContent
        let button = ExpandedPanelView.buttonSize
        let pitch = button + ExpandedPanelView.buttonSpacing
        let trailing = content.maxX - geometry.panelInset + ExpandedPanelView.skipSymbolBearing
        let forwardX = origin.x + trailing - button / 2
        let y = origin.y + content.midY
        func square(_ x: CGFloat, _ side: CGFloat) -> CGRect {
            CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
        }
        return (square(forwardX - 2 * pitch, 12), square(forwardX - pitch, 20))
    }

    /// Геометрия острова на экране с вырезом и левый верхний угол панели на снимке.
    @MainActor
    private static func expandedGeometry() -> (IslandGeometry, CGPoint) {
        let layout = notchLayout
        let geometry = IslandGeometry(layout: layout, wingWidth: CGFloat(AppSettings.Default.wingWidth))
        return (geometry, CGPoint(x: layout.panelFrame.minX, y: screenSize.height - layout.panelFrame.maxY))
    }

    /// Список снимков в каталоге: имена PNG по строке. Пишется до отрисовки, CI сверяет с ним,
    /// все ли файлы на месте.
    static let manifestName = "manifest.txt"

    /// Рисует все снимки в `directory` и возвращает пути. `demo` по умолчанию из ресурсов приложения.
    /// Прогон демо через анализатор идет вне главного актора (в отладочной сборке это секунды),
    /// на главном остается только отрисовка, и между снимками он отпускается.
    @MainActor
    static func renderAll(to directory: URL, demo: URL? = nil) async throws -> [URL] {
        guard let demoURL = demo ?? Bundle.main.url(forResource: "demo", withExtension: "wav", subdirectory: "Demo") else {
            throw SnapshotError.demoNotFound
        }
        let moments = try await Task.detached(priority: .userInitiated) {
            try DemoMoments(demo: demoURL)
        }.value
        let loudBeat = moments.loudBeat
        let loudCalm = moments.loudCalm
        let groove = moments.groove
        let silent = moments.silent

        let fallback = PaletteExtractor.fallback
        // `nil`: палитру выбирает модель по обложке трека и работе Now Playing, как в приложении.
        let fromModel: [PaletteColor]? = nil
        var noArtwork = track
        noArtwork.artworkData = nil
        let scenes = [
            SnapshotScene(name: "01-silent", state: .collapsed, moment: silent, palette: fallback),
            SnapshotScene(name: "02-loud-beat", state: .collapsed, moment: loudBeat, palette: fallback),
            SnapshotScene(name: "02-loud-beat-light", state: .collapsed, moment: loudBeat, palette: fallback, backdrop: .light),
            SnapshotScene(name: "03-loud-no-beat", state: .collapsed, moment: loudCalm, palette: fallback),
            SnapshotScene(name: "04-expanded", state: .expanded, moment: loudBeat, palette: fromModel),
            SnapshotScene(name: "04-expanded-light", state: .expanded, moment: loudBeat, palette: fromModel, backdrop: .light),
            SnapshotScene(name: "05-expanded-paused", state: .expanded, moment: silent, palette: fromModel, track: pausedTrack),
            SnapshotScene(name: "06-long-title", state: .expanded, moment: loudCalm, palette: fromModel, track: longTitleTrack),
            SnapshotScene(name: "07-palette-warm", state: .collapsed, moment: groove, palette: warmPalette),
            SnapshotScene(name: "08-palette-cold", state: .collapsed, moment: groove, palette: coldPalette),
            SnapshotScene(name: "09-pill-external", state: .collapsed, moment: loudBeat, palette: fallback, pill: true),
            SnapshotScene(name: "10-expanded-no-artwork", state: .expanded, moment: loudCalm, palette: fromModel, track: noArtwork),
            SnapshotScene(
                name: "11-expanded-no-adapter", state: .expanded, moment: loudCalm, palette: fromModel,
                nowPlaying: false
            ),
            SnapshotScene(name: "12-pill-expanded", state: .expanded, moment: loudBeat, palette: fromModel, pill: true),
        ]

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = scenes.map(\.name) + settingsScenes.map(\.name)
        let manifest = names.map { "\($0).png\n" }.joined()
        try Data(manifest.utf8).write(to: directory.appendingPathComponent(manifestName), options: .atomic)
        let defaults = snapshotDefaults()
        let model = AppModel(defaults: defaults)
        model.settings.source = source
        var written: [URL] = []
        for scene in scenes {
            let url = directory.appendingPathComponent("\(scene.name).png")
            try render(scene, model: model, to: url)
            written.append(url)
            await Task.yield()
        }
        for scene in settingsScenes {
            let url = directory.appendingPathComponent("\(scene.name).png")
            try renderSettings(name: scene.name, dark: scene.dark, tall: scene.tall, model: model, to: url)
            written.append(url)
            await Task.yield()
        }
        return written
    }

    private static var pausedTrack: NowPlayingInfo {
        var paused = track
        paused.isPlaying = false
        return paused
    }

    /// Чистые настройки по умолчанию, не настройки пользователя.
    private static func snapshotDefaults() -> UserDefaults {
        let suite = "com.wfeels.wavefeels.snapshots"
        guard let defaults = UserDefaults(suiteName: suite) else { return .standard }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private static func render(_ scene: SnapshotScene, model: AppModel, to url: URL) throws {
        let moment = scene.moment
        model.showPreview(
            state: scene.state,
            track: scene.track,
            palette: scene.palette,
            frame: moment.frame,
            motion: moment.motion,
            pulse: moment.pulse,
            time: moment.time,
            nowPlayingAvailable: scene.nowPlaying
        )
        let layout = scene.pill ? pillLayout : notchLayout
        let time = moment.time
        let content = SnapshotBackdrop(
            layout: layout,
            screenSize: screenSize,
            menuBarHeight: scene.pill ? externalMenuBarHeight : notchSize.height,
            appearance: scene.backdrop
        ) {
            IslandView(model: model, layout: layout, clock: { time })
        }

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            throw SnapshotError.renderFailed(scene.name)
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodeFailed(scene.name)
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Настройки

extension SnapshotRenderer {
    /// Источники на снимке настроек: Яндекс Музыка и Safari.
    static var settingsCatalog: SourceCatalog {
        SourceCatalog(
            yandexMusic: source,
            playing: [],
            browsers: [.application(
                bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app", displayName: "Safari"
            )]
        )
    }

    /// Окно настроек через `NSHostingView` в невидимом окне: `ImageRenderer` не рисует
    /// элементы `Form`, за которыми стоят AppKit-контролы. Окно не выводится на экран,
    /// `cacheDisplay` рисует его содержимое в битмап в масштабе экрана. Размер тот же, что у окна
    /// настроек. `tall`: ручная задержка 120 мс и подсказка о доступе к звуку.
    @MainActor
    fileprivate static func renderSettings(
        name: String,
        dark: Bool,
        tall: Bool,
        model: AppModel,
        to url: URL
    ) throws {
        if tall {
            model.settings.latencyMode = .manual(milliseconds: 120)
            model.previewPermissionHint(true)
        }
        defer {
            if tall {
                model.settings.latencyMode = .auto
                model.previewPermissionHint(false)
            }
        }
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else {
            throw SnapshotError.renderFailed(name)
        }
        let size = SettingsView.windowSize
        let frame = NSRect(origin: .zero, size: size)
        let content = SettingsView(model: model, presence: WindowPresence(), catalog: settingsCatalog) {}
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: content)
        hosting.frame = frame
        hosting.appearance = appearance

        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        // SwiftUI собирает AppKit-контролы при раскладке; короткий оборот цикла событий дает
        // ей закончить отложенные обновления.
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hosting.layoutSubtreeIfNeeded()

        let bounds = hosting.bounds
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.renderFailed(name)
        }
        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: bounds, to: bitmap)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodeFailed(name)
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Сцены

private struct SnapshotScene {
    let name: String
    let state: IslandState
    let moment: DemoMoment
    /// `nil`: палитра из модели (обложка трека, если Now Playing работает).
    let palette: [PaletteColor]?
    let backdrop: SnapshotBackdropAppearance
    let pill: Bool
    let track: NowPlayingInfo?
    /// Now Playing работает: в панели кнопки и прогресс.
    let nowPlaying: Bool

    init(
        name: String, state: IslandState, moment: DemoMoment, palette: [PaletteColor]?,
        backdrop: SnapshotBackdropAppearance = .dark, pill: Bool = false,
        track: NowPlayingInfo? = SnapshotRenderer.track, nowPlaying: Bool = true
    ) {
        self.name = name
        self.state = state
        self.moment = moment
        self.palette = palette
        self.backdrop = backdrop
        self.pill = pill
        self.track = track
        self.nowPlaying = nowPlaying
    }
}

/// Моменты демо для снимков: удар и спокойный миг громкой музыки, удар в конце и тишина после
/// обнуления звука. Считаются вне главного актора.
nonisolated private struct DemoMoments: Sendable {
    let loudBeat: DemoMoment
    let loudCalm: DemoMoment
    let groove: DemoMoment
    let silent: DemoMoment

    init(demo: URL) throws {
        let audio = try DemoAudioSource.loadMono(demo)
        let music = DemoRun(samples: audio.samples, sampleRate: audio.sampleRate, duration: 12.7, mutedFrom: nil)
        let fading = DemoRun(samples: audio.samples, sampleRate: audio.sampleRate, duration: 8, mutedFrom: 6)
        loudBeat = music.strongestBeat(in: 8.0...8.7)
        loudCalm = music.calmest(in: 8.25...8.5)
        groove = music.strongestBeat(in: 12.0...12.7)
        silent = fading.last
    }
}

/// Состояние острова на момент `time` прогона демо.
nonisolated private struct DemoMoment: Sendable {
    let time: Double
    let frame: WaveFrame
    let motion: WaveMotion
    let pulse: BeatPulse
}

/// Прогон демо через `Analyzer` вне реального времени, кадр каждые 1/60 с.
/// После `mutedFrom` секунд звук обнуляется.
nonisolated private struct DemoRun {
    static let frameStep = 1.0 / 60

    let moments: [DemoMoment]

    init(samples: [Float], sampleRate: Double, duration: Double, mutedFrom: Double?) {
        let analyzer = Analyzer(sampleRate: sampleRate)
        let size = Analyzer.fftSize
        let mutedIndex = mutedFrom.map { Int($0 * sampleRate) } ?? Int.max
        var motion = WaveMotion()
        var pulse = BeatPulse()
        var window = [Float](repeating: 0, count: size)
        var moments: [DemoMoment] = []
        let count = Int((duration / Self.frameStep).rounded())
        moments.reserveCapacity(count)

        for step in 1...max(count, 1) {
            let time = Double(step) * Self.frameStep
            let end = Int(time * sampleRate)
            for offset in 0..<size {
                let index = end - size + offset
                window[offset] = index >= 0 && index < samples.count && index < mutedIndex ? samples[index] : 0
            }
            let frame = analyzer.process(samples: window, time: time, dt: Self.frameStep, settings: LevelSettings())
            motion.advance(layers: frame.layers, dt: Self.frameStep)
            pulse.step(beat: frame.beat, dt: Self.frameStep)
            moments.append(DemoMoment(time: time, frame: frame, motion: motion, pulse: pulse))
        }
        self.moments = moments
    }

    var last: DemoMoment { moments[moments.count - 1] }

    /// Пик «вздоха» в промежутке: сразу после сильной доли.
    func strongestBeat(in range: ClosedRange<Double>) -> DemoMoment {
        moments.filter { range.contains($0.time) }.max { $0.pulse.value < $1.pulse.value } ?? last
    }

    /// Самый спокойный «вздох» в промежутке: музыка играет, удара нет.
    func calmest(in range: ClosedRange<Double>) -> DemoMoment {
        moments.filter { range.contains($0.time) }.min { $0.pulse.value < $1.pulse.value } ?? last
    }
}

// MARK: - Фон

enum SnapshotBackdropAppearance {
    case dark, light
}

/// Экран вокруг острова: обои, прозрачная строка меню macOS 26 с пунктами и часами, аппаратный
/// вырез. Остров стоит на своем месте из `NotchLayout`.
private struct SnapshotBackdrop<Island: View>: View {
    let layout: NotchLayout
    let screenSize: CGSize
    let menuBarHeight: CGFloat
    let appearance: SnapshotBackdropAppearance
    @ViewBuilder let island: () -> Island

    var body: some View {
        let panel = layout.panelFrame
        ZStack(alignment: .topLeading) {
            wallpaper
            menuBar
                .frame(width: screenSize.width, height: menuBarHeight)
            if layout.hasNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                    .fill(Color.black)
                    .frame(width: layout.notch.width, height: layout.notch.height)
                    .offset(x: layout.notch.minX, y: screenSize.height - layout.notch.maxY)
            }
            island()
                .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                .offset(x: panel.minX, y: screenSize.height - panel.maxY)
        }
        .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, appearance == .dark ? .dark : .light)
    }

    private var wallpaper: some View {
        let colors: [Color] = switch appearance {
        case .dark:
            [Color(red: 0.106, green: 0.137, blue: 0.278), Color(red: 0.165, green: 0.122, blue: 0.310), Color(red: 0.055, green: 0.184, blue: 0.290)]
        case .light:
            [Color(red: 0.812, green: 0.878, blue: 0.969), Color(red: 0.902, green: 0.863, blue: 0.953), Color(red: 0.965, green: 0.890, blue: 0.863)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(width: screenSize.width, height: screenSize.height)
    }

    private var menuBar: some View {
        let ink = appearance == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
        let tint = appearance == .dark ? Color.black.opacity(0.12) : Color.white.opacity(0.18)
        return ZStack {
            tint
            HStack(spacing: 14) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 14, weight: .medium))
                Text("Finder")
                    .font(.system(size: 13, weight: .bold))
                Text("Файл")
                Text("Правка")
                Spacer(minLength: 0)
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text("Ср 22 окт.  9:41")
            }
            .font(.system(size: 13))
            .foregroundStyle(ink)
            .padding(.horizontal, 16)
        }
    }
}
