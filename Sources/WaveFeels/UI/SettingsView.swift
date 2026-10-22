import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WaveCore

/// Окно настроек: две вкладки, «Основные» и «Вид» (`AppearanceSettingsView`), каждая `Form` в
/// стиле Системных настроек, изменения применяются сразу. Живой предпросмотр острова во вкладке
/// «Вид» идет, только пока окно открыто, видно и выбрана она (`PreviewPlayer.isActive`).
///
/// Пока окно открыто и не свернуто, задержка «Авто», статус запуска при входе и доступ к звуку
/// обновляются раз в 3 с. Список источников (поиск Яндекс Музыки, браузеры, приложения со звуком)
/// дороже: он обновляется при открытии окна, при запуске и закрытии приложений и не чаще раза
/// в 10 с.
struct SettingsView: View {
    /// Вкладки окна.
    enum Tab: Hashable, CaseIterable {
        case general, appearance
    }

    /// Размер окна: «Основные» в самом высоком состоянии (ручная задержка, подсказка о доступе
    /// к звуку и кнопка настроек конфиденциальности под ней) помещаются без прокрутки. На
    /// маленьком экране окно ужимается до его видимой области (`WindowsController`).
    static let windowSize = CGSize(width: 520, height: 880)
    static let minSize = CGSize(width: 480, height: 420)
    static let statusInterval: Duration = .seconds(3)
    /// Список источников обновляется раз в столько обновлений статуса, то есть раз в 12 с.
    static let catalogEvery = 4
    static let catalogDebounce: Duration = .seconds(1)
    static let sliderWidth: CGFloat = 190
    static let valueWidth: CGFloat = 52

    let model: AppModel
    let presence: WindowPresence
    let openDiagnostics: @MainActor () -> Void
    /// Приложение лежит в `/Applications` (у снимков задано).
    private let inApplications: Bool
    /// Снимки: экран острова для предела крыла задан.
    private let fixedScreen: NotchLayout?

    @State private var tab: Tab
    @State private var catalog: SourceCatalog
    @State private var icons: AppIconCache
    @State private var autoLatency: Int
    @State private var loginStatus: SMAppService.Status
    @State private var loginMessage: String?
    @State private var copied = false
    /// Отложенное обновление списка источников после запуска или закрытия приложения.
    @State private var catalogTask: Task<Void, Never>?
    /// Меняется, чтобы меню источника вернулось к выбранному пункту после «Выбрать приложение…».
    @State private var pickerID = 0

    /// Снимки задают все, что зависит от машины: `catalog` (готовый список источников; без него
    /// список собирается сейчас), `login` (статус запуска при входе и лежит ли приложение в
    /// `/Applications`), `screen` (экран острова) и вкладку `tab`.
    init(
        model: AppModel,
        presence: WindowPresence,
        catalog: SourceCatalog? = nil,
        login: (status: SMAppService.Status, inApplications: Bool)? = nil,
        screen: NotchLayout? = nil,
        tab: Tab = .general,
        openDiagnostics: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.presence = presence
        self.openDiagnostics = openDiagnostics
        inApplications = login?.inApplications ?? LaunchAtLogin.isInApplications
        fixedScreen = screen
        _tab = State(initialValue: tab)
        _catalog = State(initialValue: catalog ?? SourceCatalog.current(model: model))
        _icons = State(initialValue: AppIconCache())
        _autoLatency = State(initialValue: Self.autoLatencyMilliseconds(model))
        _loginStatus = State(initialValue: login?.status ?? LaunchAtLogin.status)
    }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab(value: Tab.general) {
                generalForm
            } label: {
                Text("Основные")
            }
            SwiftUI.Tab(value: Tab.appearance) {
                AppearanceSettingsView(
                    model: model,
                    active: PreviewPlayer.isActive(
                        windowOpen: presence.isOpen, windowVisible: presence.isVisible, tab: tab
                    ),
                    fixedScreen: fixedScreen
                )
            } label: {
                Text("Вид")
            }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .task(id: presence.isOpen) {
            guard presence.isOpen else { return }
            var step = 0
            while !Task.isCancelled {
                if step % Self.catalogEvery == 0 {
                    refreshCatalog()
                }
                refreshStatus()
                step += 1
                try? await Task.sleep(for: Self.statusInterval)
            }
        }
        .onReceive(workspaceCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            scheduleCatalogRefresh()
        }
        .onReceive(workspaceCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            scheduleCatalogRefresh()
        }
    }

    /// «Основные»: звук, волны, остров, система.
    private var generalForm: some View {
        Form {
            Section("Звук") {
                sourcePicker
                if model.permissionHint {
                    Label(
                        "Нет доступа к звуку. Разрешите WaveFeels «Запись системного аудио» в Системных настройках.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Button("Открыть настройки конфиденциальности") {
                        AppModel.openPrivacySettings()
                    }
                }
            }
            Section("Волны") {
                wavesRows
            }
            Section("Остров") {
                islandRows
            }
            Section("Система") {
                systemRows
            }
        }
        .formStyle(.grouped)
    }

    /// Приложения часто запускаются и закрываются пачкой: список обновляется один раз, через
    /// `catalogDebounce` после последнего события, и только пока окно открыто.
    private func scheduleCatalogRefresh() {
        catalogTask?.cancel()
        guard presence.isOpen else {
            catalogTask = nil
            return
        }
        catalogTask = Task { @MainActor in
            try? await Task.sleep(for: Self.catalogDebounce)
            guard !Task.isCancelled, presence.isOpen else { return }
            refreshCatalog()
        }
    }

    private var workspaceCenter: NotificationCenter {
        NSWorkspace.shared.notificationCenter
    }

    // MARK: - Источник звука

    private enum SourceTag: Hashable {
        case byDefault
        case source(AudioSource)
        case chooseApplication
    }

    private var sourcePicker: some View {
        let selected = model.settings.source
        let choices = SourceChoices.make(
            selected: selected,
            yandexMusic: catalog.yandexMusic,
            playing: catalog.playing,
            browsers: catalog.browsers
        )
        let defaultSource = model.defaultSource
        return Picker("Источник звука", selection: sourceSelection) {
            sourceLabel("По умолчанию (\(defaultSource.displayName))", source: defaultSource)
                .tag(SourceTag.byDefault)
            Divider()
            if let yandex = choices.yandexMusic {
                sourceItem(yandex)
            }
            if let other = choices.other {
                sourceItem(other)
            }
            if !choices.playing.isEmpty {
                Section("Приложения со звуком") {
                    ForEach(choices.playing, id: \.self) { sourceItem($0) }
                }
            }
            if !choices.browsers.isEmpty {
                Section("Браузеры") {
                    ForEach(choices.browsers, id: \.self) { sourceItem($0) }
                }
            }
            Divider()
            sourceItem(.systemWide)
            Divider()
            Text("Выбрать приложение…")
                .tag(SourceTag.chooseApplication)
        }
        .id(pickerID)
    }

    private func sourceItem(_ source: AudioSource) -> some View {
        sourceLabel(source.displayName, source: source)
            .tag(SourceTag.source(source))
    }

    private func sourceLabel(_ title: String, source: AudioSource) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: icons.icon(for: source))
        }
    }

    private var sourceSelection: Binding<SourceTag> {
        Binding(
            get: { model.settings.source.map(SourceTag.source) ?? .byDefault },
            set: { tag in
                switch tag {
                case .byDefault:
                    model.settings.source = nil
                case .source(let source):
                    model.settings.source = source
                case .chooseApplication:
                    pickerID += 1
                    Task { @MainActor in
                        chooseApplication()
                    }
                }
            }
        )
    }

    /// «Выбрать приложение…»: панель открытия в `/Applications`. Приложение сначала выходит
    /// вперед, иначе панель может оказаться за другими окнами.
    private func chooseApplication() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Выбрать приложение"
        panel.message = "Выберите приложение, звук которого будут показывать волны"
        panel.prompt = "Выбрать"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = AppModel.applicationSource(at: url.resolvingSymlinksInPath(), fallbackBundleID: nil)
        model.settings.source = source
        refreshCatalog()
    }

    // MARK: - Волны

    private enum LatencyKind: Hashable {
        case auto, manual
    }

    @ViewBuilder
    private var wavesRows: some View {
        let settings = model.settings
        SettingsSliderRow(
            "Чувствительность",
            value: Binding(
                get: { Double(settings.sensitivity) },
                set: { settings.sensitivity = Float(($0 * 20).rounded() / 20) }
            ),
            in: Double(AppSettings.Limits.sensitivity.lowerBound)...Double(AppSettings.Limits.sensitivity.upperBound),
            text: Self.multiplier(settings.sensitivity)
        )
        Picker(selection: Binding(get: { settings.levelMode }, set: { settings.levelMode = $0 })) {
            Text("Автоуровень").tag(LevelMode.auto)
            Text("Как есть").tag(LevelMode.absolute)
        } label: {
            Text("Режим уровня")
            Text(settings.levelMode == .auto
                ? "Волны одинаково живые на тихой и громкой музыке"
                : "Размах волн зависит от громкости")
        }
        Toggle(
            "Учитывать громкость системы",
            isOn: Binding(get: { settings.followSystemVolume }, set: { settings.followSystemVolume = $0 })
        )
        Picker(selection: latencyKind) {
            Text("Авто").tag(LatencyKind.auto)
            Text("Вручную").tag(LatencyKind.manual)
        } label: {
            Text("Задержка волн")
            if settings.latencyMode == .auto {
                Text("Сейчас \(autoLatency) мс по устройству вывода")
            }
        }
        .pickerStyle(.segmented)
        if case .manual(let milliseconds) = settings.latencyMode {
            SettingsSliderRow(
                "Задержка вручную",
                value: Binding(
                    get: { Double(milliseconds) },
                    set: { settings.latencyMode = .manual(milliseconds: Int($0.rounded())) }
                ),
                in: Double(AppSettings.Limits.manualLatency.lowerBound)...Double(AppSettings.Limits.manualLatency.upperBound),
                text: "\(milliseconds) мс"
            )
        }
        SettingsSliderRow(
            "Сдвиг синхронизации",
            subtitle: "Меньше: свечение раньше звука, больше: позже",
            value: Binding(
                get: { Double(settings.syncOffsetMs) },
                set: { settings.syncOffsetMs = Int(($0 / 5).rounded()) * 5 }
            ),
            in: Double(AppSettings.Limits.syncOffset.lowerBound)...Double(AppSettings.Limits.syncOffset.upperBound),
            text: AppModel.syncOffsetText(settings.syncOffsetMs)
        )
    }

    private var latencyKind: Binding<LatencyKind> {
        let settings = model.settings
        return Binding(
            get: { settings.latencyMode == .auto ? .auto : .manual },
            set: { kind in
                switch kind {
                case .auto:
                    settings.latencyMode = .auto
                case .manual:
                    guard settings.latencyMode == .auto else { return }
                    // Ручной режим начинается с того, что сейчас дает «Авто»: волны не прыгают.
                    settings.latencyMode = .manual(milliseconds: autoLatency)
                }
            }
        )
    }

    // MARK: - Остров

    @ViewBuilder
    private var islandRows: some View {
        let settings = model.settings
        Toggle("Вздох на битах", isOn: Binding(get: { settings.beatPulse }, set: { settings.beatPulse = $0 }))
        SettingsSliderRow(
            "Скрывать через",
            value: Binding(get: { settings.hideDelay }, set: { settings.hideDelay = $0.rounded() }),
            in: AppSettings.Limits.hideDelay,
            text: "\(Int(settings.hideDelay.rounded())) с"
        )
        Toggle(
            "Скрывать в полноэкранном режиме",
            isOn: Binding(get: { settings.hideInFullscreen }, set: { settings.hideInFullscreen = $0 })
        )
    }

    // MARK: - Система

    @ViewBuilder
    private var systemRows: some View {
        Toggle(isOn: launchAtLogin) {
            Text("Запускать при входе в систему")
            if let hint = loginHint {
                Text(hint)
            }
        }
        // Вне /Applications включить нельзя, а уже включенное можно выключить.
        .disabled(!inApplications && !LaunchAtLogin.isOn(loginStatus))
        HStack(spacing: 8) {
            if copied {
                Text("Скопировано")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Проверить доступ к звуку") {
                model.checkAudioPermission()
                openDiagnostics()
            }
            Button("Скопировать диагностику") {
                model.copyDiagnostics()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isOn(loginStatus) },
            set: { enabled in
                loginMessage = LaunchAtLogin.set(enabled)
                loginStatus = LaunchAtLogin.status
            }
        )
    }

    private var loginHint: String? {
        if let loginMessage { return loginMessage }
        if !inApplications { return LaunchAtLogin.moveHint }
        return loginStatus == .requiresApproval ? LaunchAtLogin.approvalHint : nil
    }

    // MARK: - Строки

    /// «1.0×», «0.25×», «2.35×»: одна цифра после точки, если второй нет.
    static func multiplier(_ value: Float) -> String {
        let hundredths = Int((Double(value) * 100).rounded())
        let format = hundredths % 10 == 0 ? "%.1f×" : "%.2f×"
        return String(format: format, Double(hundredths) / 100)
    }

    // MARK: - Обновление

    private func refreshCatalog() {
        let fresh = SourceCatalog.current(model: model)
        if fresh != catalog { catalog = fresh }
    }

    /// Задержка вывода по устройству («Авто»), миллисекунды.
    private static func autoLatencyMilliseconds(_ model: AppModel) -> Int {
        AppModel.milliseconds(LatencyCalculator.outputLatency(model.output.latency, mode: .auto))
    }

    private func refreshStatus() {
        let latency = Self.autoLatencyMilliseconds(model)
        if latency != autoLatency { autoLatency = latency }
        let status = LaunchAtLogin.status
        if status != loginStatus {
            loginStatus = status
            loginMessage = nil
        }
        model.checkAudioPermission()
    }
}

/// Строка с ползунком: подпись (и пояснение под ней) слева, ползунок и его значение справа.
struct SettingsSliderRow: View {
    let title: String
    let subtitle: String?
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let text: String

    init(_ title: String, subtitle: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>, text: String) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.range = range
        self.text = text
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .labelsHidden()
                    .frame(width: SettingsView.sliderWidth)
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: SettingsView.valueWidth, alignment: .trailing)
            }
        } label: {
            Text(title)
            if let subtitle {
                Text(subtitle)
            }
        }
    }
}

/// Найденные источники для списка «Источник звука»: Яндекс Музыка, приложения со звуком
/// (выводящие звук первыми) и установленные браузеры. Повторы убирает `SourceChoices.make`.
struct SourceCatalog: Equatable {
    var yandexMusic: AudioSource?
    var playing: [AudioSource]
    var browsers: [AudioSource]

    @MainActor
    static func current(model: AppModel) -> SourceCatalog {
        let workspace = NSWorkspace.shared
        let browsers = SourceChoices.browserBundleIDs.compactMap { bundleID -> AudioSource? in
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return AppModel.applicationSource(at: url, fallbackBundleID: bundleID)
        }
        // Тот же поиск, что у источника по умолчанию; без Яндекс Музыки он дает весь звук системы.
        let resolved = model.resolveDefaultSource()
        var yandexMusic: AudioSource?
        if case .application = resolved {
            yandexMusic = resolved
        }
        return SourceCatalog(
            yandexMusic: yandexMusic,
            playing: model.processList.runningAudioApps(),
            browsers: browsers
        )
    }
}

/// Значки 16 pt для меню источников, по пути бандла.
@MainActor
final class AppIconCache {
    static let size = NSSize(width: 16, height: 16)

    private var icons: [String: NSImage] = [:]
    private var systemIcon: NSImage?

    func icon(for source: AudioSource) -> NSImage {
        switch source {
        case .systemWide:
            if let systemIcon { return systemIcon }
            let image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
                ?? NSImage(size: Self.size)
            systemIcon = image
            return image
        case .application(_, let path, _):
            if let cached = icons[path] { return cached }
            let workspace = NSWorkspace.shared
            let icon = FileManager.default.fileExists(atPath: path)
                ? workspace.icon(forFile: path)
                : workspace.icon(for: .applicationBundle)
            // Копия: NSWorkspace может отдавать общий экземпляр, а размер меняется только здесь.
            let image = (icon.copy() as? NSImage) ?? icon
            image.size = Self.size
            icons[path] = image
            return image
        }
    }
}
