import AppKit
import Combine
import SwiftUI
import WaveCore

/// Вкладка «Вид»: живой предпросмотр острова и все настройки вида волн. Изменения применяются
/// сразу, и к острову, и к предпросмотру; значения проходят через `AppSettings`, который держит
/// их в пределах и заменяет не конечные. Строки, которые выбранный стиль не рисует, скрыты
/// (`WaveLook.usesLineCount`, `WaveLook.usesSpectrumPeaks`); сохраненные значения при этом не
/// меняются. «След пиков» у «Спектра» стоит на месте скрытого «Количества волн», поэтому вкладка
/// не становится выше. Предпросмотр вспыхивает по сетке долей демо-записи (`DemoTimeline`) при любом
/// режиме «Свечения».
struct AppearanceSettingsView: View {
    let model: AppModel
    /// Игрок предпросмотра; живет в `SettingsView`, а не создается на каждом пересчете вкладки.
    let player: PreviewPlayer
    /// Предпросмотр идет (`PreviewPlayer.isActive`).
    let active: Bool
    /// Снимки: экран острова задан, а не берется с текущих экранов.
    let fixedScreen: NotchLayout?

    /// Экран острова, как его видит `NotchWindowController`: по нему предел крыла.
    @State private var screen: NotchLayout?

    init(model: AppModel, player: PreviewPlayer, active: Bool, fixedScreen: NotchLayout? = nil) {
        self.model = model
        self.player = player
        self.active = active
        self.fixedScreen = fixedScreen
        _screen = State(initialValue: fixedScreen)
    }

    var body: some View {
        Form {
            Section {
                IslandPreview(model: model, player: player, active: active, wingLimit: wingLimit)
                if let hint = Self.costHint(for: model.settings.appearance) {
                    Label(hint, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Линии") {
                lookRow
                colorRows
                flowRows
                waveRows
            }
            Section("Свечение") {
                glowModeRow
                glowRows
            }
            Section("Крылья") {
                wingRow
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

    /// Строка под предпросмотром, когда вид дорог в отрисовке (`WaveAppearance.isRenderCostHigh`:
    /// примерная цена выше 2.5 при 1 у вида по умолчанию).
    static func costHint(for appearance: WaveAppearance) -> String? {
        appearance.isRenderCostHigh ? "Высокая нагрузка на процессор" : nil
    }

    // MARK: - Крылья и цвет

    /// Предел крыла на экране с вырезом; у капсулы крыльев нет.
    private var wingLimit: CGFloat? {
        guard let screen, screen.hasNotch else { return nil }
        return screen.wingLimit
    }

    /// Подпись под «Шириной крыльев», когда экран с вырезом не дает крылу `wing` pt и остров
    /// рисует его по пределу `limit` (до целого pt вниз). Без выреза крыльев нет, подписи тоже.
    static func wingCaption(wing: Double, limit: CGFloat?, hasNotch: Bool) -> String? {
        guard hasNotch, let limit, limit.isFinite, CGFloat(wing) > limit else { return nil }
        return "ограничено до \(Int(limit.rounded(.down))) pt"
    }

    private var wingRow: some View {
        let settings = model.settings
        return SettingsSliderRow(
            "Ширина крыльев",
            subtitle: Self.wingCaption(
                wing: settings.wingWidth, limit: screen?.wingLimit, hasNotch: screen?.hasNotch ?? false
            ),
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

    /// «Цвет по частотам» и «Скорость переливания» (0...1 с шагом 0.05, 0 выключает).
    @ViewBuilder
    private var flowRows: some View {
        let settings = model.settings
        Toggle(isOn: Binding(get: { settings.colorByBand }, set: { settings.colorByBand = $0 })) {
            Text("Цвет по частотам")
            Text("Бас, середина и верх своими цветами")
        }
        SettingsSliderRow(
            "Скорость переливания",
            value: Binding(get: { settings.colorFlow }, set: { settings.colorFlow = ($0 * 20).rounded() / 20 }),
            in: AppSettings.Limits.colorFlow,
            text: SettingsText.colorFlow(speed: settings.colorFlow)
        )
    }

    // MARK: - Свечение

    /// «Свечение»: «По ритму», «Ритм и звук», «По звуку» (`GlowMode`) и подпись выбранного режима
    /// в одну строку, как у «Частоты кадров».
    private var glowModeRow: some View {
        let settings = model.settings
        return VStack(alignment: .leading, spacing: 4) {
            Picker("Свечение", selection: Binding(get: { settings.glowMode }, set: { settings.glowMode = $0 })) {
                ForEach(GlowMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(SettingsText.glowModeCaption(settings.glowMode))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

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
            "Размер свечения",
            value: Binding(get: { settings.glowSize }, set: { settings.glowSize = ($0 * 10).rounded() / 10 }),
            in: WaveAppearance.Limits.glowSize,
            text: SettingsView.multiplier(Float(settings.glowSize))
        )
        SettingsSliderRow(
            "Четкость свечения",
            value: Binding(get: { settings.glowSharpness }, set: { settings.glowSharpness = ($0 * 20).rounded() / 20 }),
            in: WaveAppearance.Limits.glowSharpness,
            text: "\(Int((settings.glowSharpness * 100).rounded())) %"
        )
        SettingsSliderRow(
            "Длительность вспышки",
            subtitle: SettingsText.flashLengthHint(scale: settings.flashLength),
            value: Binding(get: { settings.flashLength }, set: { settings.flashLength = ($0 * 10).rounded() / 10 }),
            in: AppSettings.Limits.flashLength,
            text: SettingsView.multiplier(Float(settings.flashLength))
        )
    }

    // MARK: - Волны

    /// «Стиль»: «Волны», «Спектр». Под ним у «Спектра» «След пиков» (призрак пика над линией).
    @ViewBuilder
    private var lookRow: some View {
        let settings = model.settings
        Picker("Стиль", selection: Binding(get: { settings.look }, set: { settings.look = $0 })) {
            ForEach(WaveLook.allCases, id: \.self) { look in
                Text(look.title).tag(look)
            }
        }
        .pickerStyle(.segmented)
        if settings.look.usesSpectrumPeaks {
            Toggle("След пиков", isOn: Binding(get: { settings.spectrumPeaks }, set: { settings.spectrumPeaks = $0 }))
        }
    }

    /// Строки, которые нужны выбранному стилю: у «Спектра» все, кроме количества.
    @ViewBuilder
    private var waveRows: some View {
        let settings = model.settings
        let look = settings.look
        if look.usesLineCount {
            Picker("Количество волн", selection: Binding(get: { settings.lineCount }, set: { settings.lineCount = $0 })) {
                ForEach(Array(WaveAppearance.Limits.lineCount), id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)
        }
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
        SettingsSliderRow(
            "Заливка",
            value: Binding(get: { settings.fill }, set: { settings.fill = ($0 * 20).rounded() / 20 }),
            in: WaveAppearance.Limits.fill,
            text: "\(Int((settings.fill * 100).rounded())) %"
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
