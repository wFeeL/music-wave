import AppKit
import Combine
import SwiftUI
import WaveCore

/// Вкладка «Вид»: живой предпросмотр острова и все настройки вида волн. Изменения применяются
/// сразу, и к острову, и к предпросмотру; значения проходят через `AppSettings`, который держит
/// их в пределах и заменяет не конечные.
struct AppearanceSettingsView: View {
    let model: AppModel
    /// Предпросмотр идет (`PreviewPlayer.isActive`).
    let active: Bool
    /// Снимки: экран острова задан, а не берется с текущих экранов.
    let fixedScreen: NotchLayout?

    @State private var player = PreviewPlayer()
    /// Экран острова, как его видит `NotchWindowController`: по нему предел крыла.
    @State private var screen: NotchLayout?

    init(model: AppModel, active: Bool, fixedScreen: NotchLayout? = nil) {
        self.model = model
        self.active = active
        self.fixedScreen = fixedScreen
        _screen = State(initialValue: fixedScreen)
    }

    var body: some View {
        Form {
            Section {
                IslandPreview(model: model, player: player, active: active, wingLimit: wingLimit)
            }
            Section("Остров") {
                wingRow
                colorRows
            }
            Section("Свечение") {
                glowRows
            }
            Section("Волны") {
                waveRows
            }
        }
        .formStyle(.grouped)
        .task {
            refreshScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshScreen()
        }
    }

    // MARK: - Крылья и цвет

    /// Предел крыла на экране с вырезом; у капсулы крыльев нет.
    private var wingLimit: CGFloat? {
        guard let screen, screen.hasNotch else { return nil }
        return screen.wingLimit
    }

    private var wingRow: some View {
        let settings = model.settings
        var caption: String?
        if let wingLimit, CGFloat(settings.wingWidth) > wingLimit {
            caption = "ограничено до \(Int(wingLimit.rounded(.down))) pt"
        }
        return SettingsSliderRow(
            "Ширина крыльев",
            subtitle: caption,
            value: Binding(get: { settings.wingWidth }, set: { settings.wingWidth = ($0 / 4).rounded() * 4 }),
            in: AppSettings.Limits.wingWidth,
            text: "\(Int(settings.wingWidth.rounded())) pt"
        )
    }

    private enum ColorChoice: Hashable {
        case artwork
        case preset(WavePreset)
        case custom
    }

    @ViewBuilder
    private var colorRows: some View {
        Picker("Цвет волн", selection: colorChoice) {
            Text("Из обложки").tag(ColorChoice.artwork)
            Divider()
            ForEach(WavePreset.allCases, id: \.self) { preset in
                Text(preset.title).tag(ColorChoice.preset(preset))
            }
            Divider()
            Text("Свой цвет").tag(ColorChoice.custom)
        }
        if case .custom = model.settings.colorMode {
            ColorPicker("Свой цвет", selection: customColor, supportsOpacity: false)
        }
    }

    private var colorChoice: Binding<ColorChoice> {
        let settings = model.settings
        let model = self.model
        return Binding(
            get: {
                switch settings.colorMode {
                case .artwork: .artwork
                case .preset(let preset): .preset(preset)
                case .custom: .custom
                }
            },
            set: { choice in
                switch choice {
                case .artwork:
                    settings.colorMode = .artwork
                case .preset(let preset):
                    settings.colorMode = .preset(preset)
                case .custom:
                    if case .custom = settings.colorMode { return }
                    // «Свой цвет» начинается с первого цвета, которым волны идут сейчас.
                    let current = settings.appearance.palette(artwork: model.palette).first
                    settings.colorMode = .custom(current ?? PaletteExtractor.fallback[0])
                }
            }
        )
    }

    private var customColor: Binding<Color> {
        let settings = model.settings
        return Binding(
            get: {
                guard case .custom(let color) = settings.colorMode else {
                    return Color(palette: PaletteExtractor.fallback[0])
                }
                return Color(palette: color)
            },
            set: { color in
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                settings.colorMode = .custom(PaletteColor(
                    r: Float(srgb.redComponent), g: Float(srgb.greenComponent), b: Float(srgb.blueComponent)
                ))
            }
        )
    }

    // MARK: - Свечение

    @ViewBuilder
    private var glowRows: some View {
        let settings = model.settings
        SettingsSliderRow(
            "Яркость свечения",
            value: Binding(get: { settings.glowIntensity }, set: { settings.glowIntensity = ($0 * 100).rounded() / 100 }),
            in: AppSettings.Limits.glowIntensity,
            text: "\(Int((settings.glowIntensity * 100).rounded())) %"
        )
        SettingsSliderRow(
            "Радиус свечения",
            value: Binding(get: { settings.glowRadius }, set: { settings.glowRadius = ($0 * 10).rounded() / 10 }),
            in: WaveAppearance.Limits.glowRadius,
            text: SettingsView.multiplier(Float(settings.glowRadius))
        )
    }

    // MARK: - Волны

    @ViewBuilder
    private var waveRows: some View {
        let settings = model.settings
        Picker("Количество волн", selection: Binding(get: { settings.lineCount }, set: { settings.lineCount = $0 })) {
            ForEach(Array(WaveAppearance.Limits.lineCount), id: \.self) { count in
                Text("\(count)").tag(count)
            }
        }
        .pickerStyle(.segmented)
        SettingsSliderRow(
            "Заливка",
            value: Binding(get: { settings.fill }, set: { settings.fill = ($0 * 20).rounded() / 20 }),
            in: WaveAppearance.Limits.fill,
            text: "\(Int((settings.fill * 100).rounded())) %"
        )
        SettingsSliderRow(
            "Толщина линий",
            value: Binding(get: { settings.lineThickness }, set: { settings.lineThickness = ($0 * 20).rounded() / 20 }),
            in: WaveAppearance.Limits.thickness,
            text: SettingsView.multiplier(Float(settings.lineThickness))
        )
        SettingsSliderRow(
            "Размах",
            value: Binding(get: { settings.waveAmplitude }, set: { settings.waveAmplitude = ($0 * 20).rounded() / 20 }),
            in: WaveAppearance.Limits.amplitude,
            text: SettingsView.multiplier(Float(settings.waveAmplitude))
        )
    }

    // MARK: - Экран

    /// Экран острова по текущим экранам, тем же путем, что у `NotchWindowController`.
    private func refreshScreen() {
        guard fixedScreen == nil else { return }
        let screens = NSScreen.screens.map(NotchWindowController.descriptor(for:))
        let layout = NotchGeometry.layout(for: screens, fakeNotch: model.arguments.fakeNotch)
        if layout != screen {
            screen = layout
        }
    }
}
