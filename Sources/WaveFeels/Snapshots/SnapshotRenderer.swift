import AppKit
import SwiftUI
import WaveCore

enum SnapshotError: Error, CustomStringConvertible {
    case demoNotFound
    case renderFailed(String)
    case encodeFailed(String)

    var description: String {
        switch self {
        case .demoNotFound: "нет Demo/demo.wav в ресурсах приложения"
        case .renderFailed(let name): "ImageRenderer не отрисовал \(name)"
        case .encodeFailed(let name): "не удалось записать PNG \(name)"
        }
    }
}

/// Снимки острова для CI: PNG в масштабе 2 на фоне строки меню macOS.
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

    static let track = NowPlayingInfo(
        bundleIdentifier: "ru.yandex.desktop.music",
        title: "Ночной город",
        artist: "Синтетика",
        isPlaying: true,
        duration: 214,
        elapsedTime: 63
    )
    static let longTitleTrack = NowPlayingInfo(
        bundleIdentifier: "ru.yandex.desktop.music",
        title: "Очень длинное название трека, которое целиком не помещается в панель",
        artist: "Оркестр синтезаторов и голосов",
        isPlaying: true,
        duration: 377,
        elapsedTime: 141
    )

    /// Экран со встроенным вырезом по центру.
    static var notchLayout: NotchLayout {
        let side = (screenSize.width - notchSize.width) / 2
        let screen = ScreenDescriptor(
            id: 1, frame: CGRect(origin: .zero, size: screenSize), safeAreaTop: notchSize.height,
            auxiliaryLeftWidth: side, auxiliaryRightWidth: side, isBuiltIn: true, menuBarHeight: notchSize.height
        )
        return NotchGeometry.layout(for: [screen])!
    }

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

    /// Рисует все снимки в `directory` и возвращает пути. `demo` по умолчанию из ресурсов приложения.
    @MainActor
    static func renderAll(to directory: URL, demo: URL? = nil) throws -> [URL] {
        guard let demoURL = demo ?? Bundle.main.url(forResource: "demo", withExtension: "wav", subdirectory: "Demo") else {
            throw SnapshotError.demoNotFound
        }
        let audio = try DemoAudioSource.loadMono(demoURL)
        let music = DemoRun(samples: audio.samples, sampleRate: audio.sampleRate, duration: 12.7, mutedFrom: nil)
        let fading = DemoRun(samples: audio.samples, sampleRate: audio.sampleRate, duration: 8, mutedFrom: 6)
        let loudBeat = music.strongestBeat(in: 8.0...8.7)
        let loudCalm = music.calmest(in: 8.25...8.5)
        let groove = music.strongestBeat(in: 12.0...12.7)
        let silent = fading.last

        let fallback = PaletteExtractor.fallback
        let scenes = [
            SnapshotScene(name: "01-silent", state: .collapsed, moment: silent, palette: fallback),
            SnapshotScene(name: "02-loud-beat", state: .collapsed, moment: loudBeat, palette: fallback),
            SnapshotScene(name: "02-loud-beat-light", state: .collapsed, moment: loudBeat, palette: fallback, backdrop: .light),
            SnapshotScene(name: "03-loud-no-beat", state: .collapsed, moment: loudCalm, palette: fallback),
            SnapshotScene(name: "04-expanded", state: .expanded, moment: loudBeat, palette: fallback),
            SnapshotScene(name: "04-expanded-light", state: .expanded, moment: loudBeat, palette: fallback, backdrop: .light),
            SnapshotScene(name: "05-expanded-paused", state: .expanded, moment: silent, palette: fallback, track: pausedTrack),
            SnapshotScene(name: "06-long-title", state: .expanded, moment: loudCalm, palette: fallback, track: longTitleTrack),
            SnapshotScene(name: "07-palette-warm", state: .collapsed, moment: groove, palette: warmPalette),
            SnapshotScene(name: "08-palette-cold", state: .collapsed, moment: groove, palette: coldPalette),
            SnapshotScene(name: "09-pill-external", state: .collapsed, moment: loudBeat, palette: fallback, pill: true),
        ]

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = snapshotDefaults()
        let model = AppModel(defaults: defaults)
        var written: [URL] = []
        for scene in scenes {
            let url = directory.appendingPathComponent("\(scene.name).png")
            try render(scene, model: model, to: url)
            written.append(url)
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
            time: moment.time
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

// MARK: - Сцены

private struct SnapshotScene {
    let name: String
    let state: IslandState
    let moment: DemoMoment
    let palette: [PaletteColor]
    let backdrop: SnapshotBackdropAppearance
    let pill: Bool
    let track: NowPlayingInfo?

    init(
        name: String, state: IslandState, moment: DemoMoment, palette: [PaletteColor],
        backdrop: SnapshotBackdropAppearance = .dark, pill: Bool = false,
        track: NowPlayingInfo? = SnapshotRenderer.track
    ) {
        self.name = name
        self.state = state
        self.moment = moment
        self.palette = palette
        self.backdrop = backdrop
        self.pill = pill
        self.track = track
    }
}

/// Состояние острова на момент `time` прогона демо.
private struct DemoMoment {
    let time: Double
    let frame: WaveFrame
    let motion: WaveMotion
    let pulse: BeatPulse
}

/// Прогон демо через `Analyzer` вне реального времени, кадр каждые 1/60 с.
/// После `mutedFrom` секунд звук обнуляется.
private struct DemoRun {
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
