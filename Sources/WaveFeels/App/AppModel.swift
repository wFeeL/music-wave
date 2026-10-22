import AppKit
import Observation
import WaveCore

/// Цвет палитры из WaveCore. В SDK macOS есть одноименная структура QuickDraw `RGBColor`
/// (ApplicationServices), поэтому в приложении цвет называется только так.
typealias PaletteColor = WaveCore.RGBColor

/// Связывает настройки, захват звука, Now Playing и состояние острова.
///
/// Цикл 10 Гц на главном акторе: уровень из `FrameStore` идет в `ActivityGate`, Now Playing
/// источника в `IslandInputs`, затем `IslandStateMachine`. Там же настройки передаются в
/// `AudioPipeline`, а после 10 с тишины захват приостанавливается, если Now Playing работает
/// и сообщит о старте воспроизведения. Подписок и задач в `deinit` нет: владелец вызывает `stop()`.
@MainActor
@Observable
final class AppModel {
    static let tickInterval: Duration = .milliseconds(100)
    /// Сколько секунд тишины до остановки IOProc.
    static let idleSuspendDelay = 10.0
    static let logTailLines = 200
    static let privacyAudioCaptureURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    static let privacyScreenCaptureURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    /// Самый длинный шаг анимации острова между кадрами, с.
    static let maxVisualStep = 0.1
    /// Сколько трек может быть без обложки, прежде чем панель и волны вернутся к стандартной
    /// палитре: адаптер иногда присылает обложку следом за названием.
    static let missingArtworkGrace: Duration = .milliseconds(500)

    let settings: AppSettings
    let store: FrameStore
    let pipeline: AudioPipeline
    let adapter: MediaRemoteAdapter
    /// Те же объекты, что внутри `pipeline`; нужны настройкам и диагностике.
    let processList: AudioProcessList
    let output: OutputDeviceMonitor

    private(set) var islandState: IslandState = .hidden
    /// Последний трек выбранного источника, держится и на паузе.
    private(set) var lastTrack: NowPlayingInfo?
    /// Палитра волн: из обложки `lastTrack`, без обложки стандартная. Остров переходит к ней
    /// плавно (`PaletteFade`).
    private(set) var palette: [PaletteColor] = PaletteExtractor.fallback
    /// Обложка `lastTrack` для панели, уже уменьшенная до `ExpandedPanelView.artworkPixels`.
    private(set) var artwork: PanelArtwork?
    /// Показать подсказку о доступе к звуку.
    private(set) var permissionHint = false
    /// Последний результат `AudioCapturePermission.preflight()`.
    private(set) var permissionStatus: AudioCapturePermission.Status = .unknown
    /// Источник, когда пользователь его не выбрал (`settings.source == nil`). Определяется при
    /// каждом запуске и при запуске или закрытии приложений, в настройки не пишется.
    private(set) var defaultSource: AudioSource = .systemWide
    var pointerInHoverZone = false
    var fullscreenSuppressed = false
    var screenLocked = false
    /// Режим энергосбережения: остров рисуется не чаще 30 кадров в секунду.
    var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Фазы волн. Сдвигаются на каждом кадре отрисовки, поэтому не наблюдаются.
    @ObservationIgnored var motion = WaveMotion()

    @ObservationIgnored private(set) var arguments = LaunchArguments()
    @ObservationIgnored private var gate = ActivityGate()
    @ObservationIgnored private var machine = IslandStateMachine()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var appObservers: [any NSObjectProtocol] = []
    /// Первый `checkAudioPermission()` после запуска только запоминает статус.
    @ObservationIgnored private var permissionChecked = false
    /// `defaultSource` надо определить заново: запуск, запуск или закрытие приложения,
    /// пользователь снял свой выбор.
    @ObservationIgnored private var defaultSourceStale = true
    @ObservationIgnored private var appliedSource: AudioSource?
    @ObservationIgnored private var sourceAppRunning = false
    @ObservationIgnored private var silentSince: Double?
    @ObservationIgnored private var watchdogExhausted = false
    @ObservationIgnored private var cachedSigning: String?
    @ObservationIgnored private var pulse = BeatPulse()
    @ObservationIgnored private var paletteFade = PaletteFade(palette: PaletteExtractor.fallback)
    @ObservationIgnored private var lastVisualTime: Double?
    /// Обложка, из которой получены `artwork` и `palette` (или ждут разбора).
    @ObservationIgnored private var artworkData: Data?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// Номер последнего запроса обложки: ответы старых запросов отбрасываются.
    @ObservationIgnored private var artworkGeneration = 0
    /// Снимки: работает ли Now Playing, вместо `adapter.isAvailable`.
    @ObservationIgnored private var previewNowPlaying: Bool?

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        settings = AppSettings(defaults: defaults)
        let store = FrameStore()
        let processList = AudioProcessList()
        let output = OutputDeviceMonitor()
        self.store = store
        self.processList = processList
        self.output = output
        pipeline = AudioPipeline(store: store, processes: processList, output: output)
        adapter = MediaRemoteAdapter(bundle: bundle, defaults: defaults)
    }

    // MARK: - Запуск и остановка

    /// `--demo`: звук из файла; `--no-capture`: без tap и без адаптера; иначе обычный захват.
    func start(arguments: LaunchArguments) {
        guard loopTask == nil else { return }
        self.arguments = arguments

        applySettings()
        subscribeToNotifications()
        refreshSourceAppRunning()

        if let file = arguments.demoFile {
            do {
                try pipeline.startDemo(file: file)
            } catch {
                log("демо не запустилось: \(error.localizedDescription)")
            }
        } else if arguments.noCapture {
            log("захват звука выключен (--no-capture)")
        } else {
            pipeline.start()
        }
        if !arguments.noCapture {
            adapter.start()
        }
        checkAudioPermission()

        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// Останавливает цикл, подписки, захват и процессы адаптера.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers = []
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appObservers = []
        pipeline.stop()
        adapter.stop()
        artworkTask?.cancel()
        artworkTask = nil
        silentSince = nil
    }

    /// Остров принудительно скрыт и на курсор не отвечает: пауза, блокировка экрана или
    /// полноэкранное окно при включенной настройке.
    var islandSuppressed: Bool {
        settings.paused || screenLocked || (fullscreenSuppressed && settings.hideInFullscreen)
    }

    // MARK: - Источник по умолчанию

    /// Источник, который сейчас используется: выбранный пользователем или по умолчанию.
    var effectiveSource: AudioSource {
        settings.source ?? defaultSource
    }

    private func refreshDefaultSource() {
        defaultSourceStale = false
        let source = resolveDefaultSource()
        if source != defaultSource {
            defaultSource = source
            log("источник по умолчанию: \(source.displayName)")
        }
    }

    /// Яндекс Музыка по bundle ID, иначе приложение в `/Applications` с «Яндекс Музыка» или
    /// «Yandex Music» в имени, иначе весь звук системы.
    func resolveDefaultSource() -> AudioSource {
        let workspace = NSWorkspace.shared
        for bundleID in ProcessMatcher.yandexMusicCandidates {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return Self.applicationSource(at: url, fallbackBundleID: bundleID)
            }
        }
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let names = ["Яндекс Музыка", "Yandex Music"]
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "app" {
            let name = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
            if names.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                return Self.applicationSource(at: url, fallbackBundleID: nil)
            }
        }
        return .systemWide
    }

    private static func applicationSource(at url: URL, fallbackBundleID: String?) -> AudioSource {
        let path = AudioProcessList.canonicalPath(url)
        let bundle = Bundle(path: path)
        let bundleID = bundle?.bundleIdentifier ?? fallbackBundleID ?? ""
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: path)
        return .application(bundleID: bundleID, bundlePath: path, displayName: name)
    }

    /// Now Playing относится к источнику: совпал bundle ID приложения или его родителя.
    /// Для всего звука системы подходит любой.
    nonisolated static func belongs(_ info: NowPlayingInfo, to source: AudioSource) -> Bool {
        switch source {
        case .systemWide:
            return true
        case .application(let bundleID, _, _):
            guard !bundleID.isEmpty else { return false }
            return info.bundleIdentifier == bundleID || info.parentBundleIdentifier == bundleID
        }
    }

    // MARK: - Доступ к звуку

    /// Перечитывает статус доступа и пересчитывает `permissionHint`.
    /// Если доступ стал разрешенным (не при первой проверке), счетчик сторожа нулей
    /// сбрасывается и tap пересобирается.
    func checkAudioPermission() {
        applyPermissionStatus(AudioCapturePermission.preflight())
        updatePermissionHint()
    }

    private func applyPermissionStatus(_ status: AudioCapturePermission.Status) {
        let previous = permissionStatus
        let firstCheck = !permissionChecked
        permissionChecked = true
        guard status != previous else { return }
        permissionStatus = status
        log("доступ к звуку: \(Self.describe(previous)) -> \(Self.describe(status))")
        if status == .authorized, !firstCheck {
            pipeline.resetWatchdog()
            pipeline.rebuild(reason: "доступ к звуку разрешен")
        }
    }

    /// Системный запрос доступа; после ответа tap пересобирается.
    func requestAudioPermission() {
        log("запрос доступа к звуку")
        AudioCapturePermission.request { granted in
            Task { @MainActor in
                self.audioPermissionAnswered(granted)
            }
        }
    }

    /// Раздел «Запись системного аудио»; если он не открылся, «Запись экрана» рядом с ним.
    static func openPrivacySettings() {
        let workspace = NSWorkspace.shared
        if let url = URL(string: privacyAudioCaptureURL), workspace.open(url) { return }
        if let url = URL(string: privacyScreenCaptureURL) {
            _ = workspace.open(url)
        }
    }

    /// Диагностика и последние 200 строк лога в буфер обмена.
    func copyDiagnostics() {
        checkAudioPermission()
        let lines = Log.recentLines(Self.logTailLines)
        let text = diagnosticsText()
            + "\n\n## Лог (последние \(Self.logTailLines) строк)\n"
            + (lines.isEmpty ? "пусто" : lines.joined(separator: "\n"))
            + "\n"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        log("диагностика скопирована")
    }

    private func audioPermissionAnswered(_ granted: Bool) {
        log("ответ на запрос доступа к звуку: \(granted ? "разрешено" : "не разрешено")")
        checkAudioPermission()
        if pipeline.status == .suspended {
            pipeline.resume()
        } else {
            pipeline.rebuild(reason: "доступ к звуку")
        }
    }

    private func updatePermissionHint() {
        let exhausted = pipeline.watchdogRebuilds >= AudioPipeline.maxWatchdogRebuilds
        if exhausted != watchdogExhausted {
            watchdogExhausted = exhausted
            // Сторож исчерпал попытки: стоит заново спросить TCC, вдруг доступ отозвали.
            if exhausted {
                applyPermissionStatus(AudioCapturePermission.preflight())
            }
        }
        let hint = permissionStatus == .denied || (permissionStatus == .unknown && exhausted)
        if hint != permissionHint {
            permissionHint = hint
            log(hint ? "подсказка о доступе к звуку показана" : "подсказка о доступе к звуку снята")
        }
    }

    // MARK: - Цикл 10 Гц

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        applySettings()

        let source = effectiveSource
        let info = adapter.info
        let sourceInfo = info.flatMap { Self.belongs($0, to: source) ? $0 : nil }
        let sourcePlaying = sourceInfo?.isPlaying ?? false
        if let sourceInfo, sourceInfo != lastTrack {
            lastTrack = sourceInfo
            updateArtwork()
        }

        pipeline.adapterAvailable = adapter.isAvailable
        pipeline.adapterSaysPlaying = sourcePlaying

        let audioActive = gate.update(levelDB: store.latest.rawLevelDB, now: now)
        manageIdleCapture(audioActive: audioActive, sourcePlaying: sourcePlaying, now: now)

        let inputs = IslandInputs(
            audioActive: audioActive,
            sourcePlaying: sourcePlaying,
            sourceRunning: source == .systemWide ? info != nil : sourceAppRunning,
            hasLastTrack: lastTrack != nil,
            pointerInHoverZone: pointerInHoverZone,
            fullscreenSuppressed: fullscreenSuppressed && settings.hideInFullscreen,
            userPaused: settings.paused || screenLocked
        )
        machine.hideDelay = settings.hideDelay
        let state = machine.update(inputs, now: now)
        if state != islandState {
            islandState = state
        }
        updatePermissionHint()
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        if low != lowPower {
            lowPower = low
        }
    }

    /// Настройки пользователя в `AudioPipeline`. Свойства конвейера сами отбрасывают
    /// повторы, `LevelSettings` сравнивается здесь, чтобы не будить анализ каждый тик.
    private func applySettings() {
        if settings.source != nil {
            defaultSourceStale = true
        } else if defaultSourceStale {
            refreshDefaultSource()
        }
        let source = effectiveSource
        if source != appliedSource {
            appliedSource = source
            pipeline.source = source
            if let track = lastTrack, !Self.belongs(track, to: source) {
                lastTrack = nil
                updateArtwork()
            }
            refreshSourceAppRunning()
        }
        var level = pipeline.settings
        level.mode = settings.levelMode
        level.sensitivity = settings.sensitivity
        level.followSystemVolume = settings.followSystemVolume
        if level != pipeline.settings {
            pipeline.settings = level
        }
        pipeline.latencyMode = settings.latencyMode
    }

    /// После 10 с тишины IOProc останавливается, но только если Now Playing работает: без него
    /// о начале музыки узнает лишь tap. Возобновление по старту воспроизведения или если
    /// адаптер перестал работать.
    private func manageIdleCapture(audioActive: Bool, sourcePlaying: Bool, now: Double) {
        let suspended = pipeline.status == .suspended
        if audioActive || sourcePlaying {
            silentSince = nil
            if suspended { pipeline.resume() }
            return
        }
        if suspended {
            if !adapter.isAvailable {
                silentSince = nil
                pipeline.resume()
            }
            return
        }
        let since = silentSince ?? now
        silentSince = since
        if now - since >= Self.idleSuspendDelay, adapter.isAvailable {
            pipeline.suspendIdle()
        }
    }

    // MARK: - Запущенные приложения

    private func subscribeToNotifications() {
        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.applicationsChanged()
                    }
                }
                workspaceObservers.append(observer)
            }
        }
        if appObservers.isEmpty {
            // Пользователь мог выдать доступ в Системных настройках и вернуться.
            let observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkAudioPermission()
                }
            }
            appObservers.append(observer)
        }
    }

    private func applicationsChanged() {
        defaultSourceStale = true
        applySettings()
        refreshSourceAppRunning()
    }

    private func refreshSourceAppRunning() {
        guard case .application(let bundleID, let bundlePath, _) = appliedSource else {
            sourceAppRunning = false
            return
        }
        sourceAppRunning = NSWorkspace.shared.runningApplications.contains { app in
            if !bundleID.isEmpty, app.bundleIdentifier == bundleID { return true }
            guard let url = app.bundleURL else { return false }
            return AudioProcessList.canonicalPath(url) == bundlePath
        }
    }

    // MARK: - Обложка и палитра

    /// Now Playing работает: в панели есть трек, кнопки и прогресс.
    var nowPlayingAvailable: Bool {
        previewNowPlaying ?? adapter.isAvailable
    }

    /// Обложка `lastTrack` сменилась: картинка для панели и палитра считаются вне главного
    /// актора, затем палитра плавно перетекает в новую. Трек без обложки (или без трека)
    /// через `missingArtworkGrace` получает стандартную палитру. На паузе `lastTrack` и его
    /// обложка остаются.
    private func updateArtwork() {
        let data = lastTrack?.artworkData
        guard data != artworkData else { return }
        artworkData = data
        artworkTask?.cancel()
        artworkGeneration += 1
        let generation = artworkGeneration
        let pixels = ExpandedPanelView.artworkPixels
        artworkTask = Task { [weak self] in
            let analysis: ArtworkAnalysis?
            if let data {
                analysis = await Task.detached(priority: .utility) {
                    ArtworkAnalysis(data: data, displayPixels: pixels)
                }.value
            } else {
                do {
                    try await Task.sleep(for: Self.missingArtworkGrace)
                } catch {
                    return
                }
                analysis = nil
            }
            guard let self, !Task.isCancelled, generation == self.artworkGeneration else { return }
            self.applyArtwork(analysis, generation: generation)
        }
    }

    private func applyArtwork(_ analysis: ArtworkAnalysis?, generation: Int) {
        artwork = analysis?.image.map { PanelArtwork(image: $0, id: generation) }
        let target = analysis?.palette ?? PaletteExtractor.fallback
        if target != palette {
            palette = target
        }
        if let analysis, analysis.image == nil {
            log("обложка не прочиталась, палитра стандартная")
        }
    }

    // MARK: - Кадр острова

    /// Шаг анимации острова на момент `now` (секунды часов кадра): последний кадр анализа,
    /// фазы волн (при «Уменьшении движения» вдвое медленнее), «вздох» и палитра в середине
    /// перехода. Шаг ограничен `maxVisualStep`, повторный вызов с тем же `now` ничего не двигает.
    func islandVisuals(now: Double, reduceMotion: Bool) -> IslandVisuals {
        let frame = store.latest
        var dt = 0.0
        if let lastVisualTime, now.isFinite {
            dt = min(max(now - lastVisualTime, 0), Self.maxVisualStep)
        }
        if now.isFinite {
            lastVisualTime = now
        }
        motion.advance(layers: frame.layers, dt: reduceMotion ? dt / 2 : dt)
        let beat = pulse.step(beat: frame.beat, dt: dt)
        let shown = paletteFade.palette(target: palette, now: now)
        return IslandVisuals(frame: frame, motion: motion, palette: shown, pulse: beat, time: now)
    }

    /// Снимки острова: модель не запущена, состояние, трек, палитра и кадр задаются напрямую.
    /// Часы анимации встают на `time`, поэтому кадр на этот момент рисуется без шага анимации
    /// и без перехода палитры.
    /// Обложка трека разбирается здесь же, синхронно; палитра задается отдельно.
    func showPreview(
        state: IslandState,
        track: NowPlayingInfo?,
        palette: [PaletteColor],
        frame: WaveFrame,
        motion: WaveMotion,
        pulse: BeatPulse,
        time: Double,
        nowPlayingAvailable: Bool = true
    ) {
        islandState = state
        lastTrack = track
        artworkTask?.cancel()
        artworkTask = nil
        artworkGeneration += 1
        artworkData = track?.artworkData
        let generation = artworkGeneration
        artwork = artworkData
            .flatMap { ArtworkPixels.image(from: $0, maxPixelSize: ExpandedPanelView.artworkPixels) }
            .map { PanelArtwork(image: $0, id: generation) }
        previewNowPlaying = nowPlayingAvailable
        self.palette = palette
        store.publish(frame)
        self.motion = motion
        self.pulse = pulse
        paletteFade = PaletteFade(palette: palette)
        lastVisualTime = time
    }

    private func log(_ message: String) {
        Log.app.info("\(message, privacy: .public)")
        Log.file(message)
    }
}

/// Обложка в панели. `id` меняется с каждой новой обложкой: по нему панель плавно сменяет картинку.
struct PanelArtwork {
    let image: CGImage
    let id: Int
}

/// Все, что нужно острову на один кадр.
struct IslandVisuals {
    var frame: WaveFrame
    var motion: WaveMotion
    /// Палитра с учетом перехода.
    var palette: [PaletteColor]
    /// «Вздох» 0...1.
    var pulse: Float
    /// Время кадра, с: по нему течет градиент волн.
    var time: Double
}

// MARK: - Диагностика

struct DiagnosticsRow: Sendable, Equatable {
    var label: String
    var value: String
}

struct DiagnosticsSection: Sendable, Equatable, Identifiable {
    var title: String
    var rows: [DiagnosticsRow]

    var id: String { title }
}

extension AppModel {
    /// «0.1.0 (сборка 42)».
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (сборка \(build))"
    }

    /// Текст для буфера обмена: те же разделы, что в окне диагностики.
    func diagnosticsText() -> String {
        var lines = ["# Диагностика WaveFeels", "Время: \(Date().formatted(.iso8601))"]
        for section in diagnosticsSections() {
            lines.append("")
            lines.append("## \(section.title)")
            for row in section.rows {
                lines.append("\(row.label): \(row.value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func diagnosticsSections() -> [DiagnosticsSection] {
        [
            applicationSection(),
            nowPlayingSection(),
            audioSection(),
            outputSection(),
            permissionSection(),
            screensSection(),
        ]
    }

    private var signing: String {
        if let cachedSigning { return cachedSigning }
        let value = SigningInfo.current()
        cachedSigning = value
        return value
    }

    private func applicationSection() -> DiagnosticsSection {
        let mode: String
        if let file = arguments.demoFile {
            mode = "демо (\(file.lastPathComponent))"
        } else if arguments.noCapture {
            mode = "без захвата (--no-capture)"
        } else {
            mode = "обычный"
        }
        return DiagnosticsSection(title: "Приложение", rows: [
            DiagnosticsRow(label: "Версия", value: Self.versionDescription),
            DiagnosticsRow(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString),
            DiagnosticsRow(label: "Подпись", value: signing),
            DiagnosticsRow(label: "Режим запуска", value: mode),
            DiagnosticsRow(label: "Остров", value: Self.describe(islandState)),
            DiagnosticsRow(label: "Визуализация на паузе", value: Self.yesNo(settings.paused)),
        ])
    }

    private func nowPlayingSection() -> DiagnosticsSection {
        DiagnosticsSection(title: "Now Playing", rows: [
            DiagnosticsRow(label: "Адаптер", value: Self.describe(adapter.availability)),
            DiagnosticsRow(label: "Код test", value: adapter.lastTestExitCode.map { String($0) } ?? "нет"),
            DiagnosticsRow(label: "stderr адаптера", value: adapter.lastStderr.isEmpty ? "пусто" : adapter.lastStderr),
            DiagnosticsRow(label: "Текущий трек", value: adapter.info.map { Self.describe($0) } ?? "нет"),
            DiagnosticsRow(label: "Последний трек источника", value: lastTrack.map { Self.describe($0) } ?? "нет"),
        ])
    }

    private func audioSection() -> DiagnosticsSection {
        let source = effectiveSource
        let byDefault = settings.source == nil ? " (по умолчанию)" : ""
        var rows: [DiagnosticsRow] = []
        switch source {
        case .systemWide:
            rows.append(DiagnosticsRow(label: "Источник", value: source.displayName + byDefault))
        case .application(let bundleID, let bundlePath, let displayName):
            rows.append(DiagnosticsRow(label: "Источник", value: "\(displayName) (\(bundleID.isEmpty ? "без bundle ID" : bundleID))\(byDefault)"))
            rows.append(DiagnosticsRow(label: "Путь источника", value: bundlePath))
            rows.append(DiagnosticsRow(label: "Источник запущен", value: Self.yesNo(sourceAppRunning)))
        }
        rows.append(DiagnosticsRow(label: "Статус захвата", value: Self.describe(pipeline.status)))
        let rate: String
        if case .capturing(.running(let sampleRate, _)) = pipeline.status {
            rate = "\(Int(sampleRate.rounded())) Гц"
        } else {
            rate = "нет"
        }
        rows.append(DiagnosticsRow(label: "Частота tap", value: rate))
        rows.append(DiagnosticsRow(
            label: "Пересборок сторожа нулей",
            value: "\(pipeline.watchdogRebuilds) из \(AudioPipeline.maxWatchdogRebuilds)"
        ))
        rows.append(DiagnosticsRow(label: "Звучит по уровню", value: Self.yesNo(gate.isActive)))
        rows.append(DiagnosticsRow(label: "Играет по Now Playing", value: Self.yesNo(pipeline.adapterSaysPlaying)))
        rows.append(DiagnosticsRow(label: "Источник выводит звук", value: Self.yesNo(pipeline.sourceOutputting)))

        if source == .systemWide {
            rows.append(DiagnosticsRow(label: "Найденные процессы", value: "весь звук системы, процессы не отбираются"))
        } else if pipeline.matchedProcesses.isEmpty {
            rows.append(DiagnosticsRow(label: "Найденные процессы", value: "нет"))
        } else {
            rows.append(DiagnosticsRow(label: "Найденные процессы", value: "\(pipeline.matchedProcesses.count)"))
            for process in pipeline.matchedProcesses {
                rows.append(DiagnosticsRow(label: "pid \(process.pid)", value: Self.describe(process)))
            }
        }
        return DiagnosticsSection(title: "Звук", rows: rows)
    }

    private func outputSection() -> DiagnosticsSection {
        let latency = output.latency
        let milliseconds = LatencyCalculator.delayMilliseconds(latency, mode: settings.latencyMode)
        let mode: String
        switch settings.latencyMode {
        case .auto: mode = "авто"
        case .manual: mode = "вручную"
        }
        return DiagnosticsSection(title: "Устройство вывода", rows: [
            DiagnosticsRow(label: "Устройство", value: output.deviceName.isEmpty ? "нет" : output.deviceName),
            DiagnosticsRow(label: "UID", value: output.deviceUID.isEmpty ? "нет" : output.deviceUID),
            DiagnosticsRow(label: "Bluetooth", value: Self.yesNo(latency.isBluetooth)),
            DiagnosticsRow(label: "Громкость", value: "\(Int((output.volume * 100).rounded())) %"),
            DiagnosticsRow(label: "Без звука", value: Self.yesNo(output.isMuted)),
            DiagnosticsRow(label: "Частота устройства", value: "\(Int(latency.sampleRate.rounded())) Гц"),
            DiagnosticsRow(
                label: "Задержка устройства",
                value: "кадров: устройство \(latency.deviceFrames), поток \(latency.streamFrames), "
                    + "запас \(latency.safetyOffsetFrames), буфер \(latency.bufferFrames)"
            ),
            DiagnosticsRow(label: "Задержка волн", value: "\(milliseconds) мс (\(mode))"),
        ])
    }

    private func permissionSection() -> DiagnosticsSection {
        DiagnosticsSection(title: "Доступ", rows: [
            DiagnosticsRow(label: "Запись системного аудио", value: Self.describe(permissionStatus)),
            DiagnosticsRow(label: "Подсказка о доступе", value: permissionHint ? "показана" : "нет"),
        ])
    }

    private func screensSection() -> DiagnosticsSection {
        var rows: [DiagnosticsRow] = []
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for (index, screen) in NSScreen.screens.enumerated() {
            let name = "\(index + 1). \(screen.localizedName)"
            let insets = screen.safeAreaInsets
            let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
            let builtIn = displayID.map { CGDisplayIsBuiltin($0) != 0 }
            rows.append(DiagnosticsRow(label: "\(name), frame", value: Self.describe(screen.frame)))
            rows.append(DiagnosticsRow(
                label: "\(name), safeAreaInsets",
                value: "сверху \(Self.number(insets.top)), слева \(Self.number(insets.left)), "
                    + "снизу \(Self.number(insets.bottom)), справа \(Self.number(insets.right))"
            ))
            rows.append(DiagnosticsRow(
                label: "\(name), auxiliaryTopLeftArea",
                value: screen.auxiliaryTopLeftArea.map { Self.describe($0) } ?? "нет"
            ))
            rows.append(DiagnosticsRow(
                label: "\(name), auxiliaryTopRightArea",
                value: screen.auxiliaryTopRightArea.map { Self.describe($0) } ?? "нет"
            ))
            rows.append(DiagnosticsRow(
                label: "\(name), встроенный",
                value: builtIn.map { Self.yesNo($0) } ?? "неизвестно"
            ))
        }
        if rows.isEmpty {
            rows.append(DiagnosticsRow(label: "Экраны", value: "нет"))
        }
        return DiagnosticsSection(title: "Экраны", rows: rows)
    }

    // MARK: - Описания

    private static func yesNo(_ value: Bool) -> String {
        value ? "да" : "нет"
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private static func describe(_ rect: NSRect) -> String {
        "x \(number(rect.origin.x)), y \(number(rect.origin.y)), \(number(rect.width)) × \(number(rect.height))"
    }

    private static func describe(_ state: IslandState) -> String {
        switch state {
        case .hidden: "скрыт"
        case .collapsed: "свернут"
        case .expanded: "раскрыт"
        }
    }

    private static func describe(_ availability: AdapterAvailability) -> String {
        switch availability {
        case .unknown: "не запускался"
        case .checking: "проверка"
        case .available: "работает"
        case .unavailable(let exitCode, _): "не работает, код \(exitCode)"
        }
    }

    private static func describe(_ info: NowPlayingInfo) -> String {
        var parts = ["«\(info.title)»"]
        if let artist = info.artist, !artist.isEmpty { parts.append(artist) }
        var app = info.bundleIdentifier
        if let parent = info.parentBundleIdentifier { app += " в \(parent)" }
        parts.append(app)
        parts.append(info.isPlaying ? "играет" : "пауза")
        if info.artworkData != nil { parts.append("есть обложка") }
        return parts.joined(separator: ", ")
    }

    private static func describe(_ process: AudioProcessInfo) -> String {
        let bundleID = process.bundleID ?? "без bundle ID"
        let path = process.executablePath ?? "путь неизвестен"
        return "\(bundleID), \(path), звук: \(yesNo(process.isRunningOutput))"
    }

    private static func describe(_ status: PipelineStatus) -> String {
        switch status {
        case .stopped: "остановлен"
        case .demo: "демо из файла"
        case .capturing(.running(_, let processCount)): "захват идет, процессов в tap: \(processCount)"
        case .capturing(.idle): "tap не создан"
        case .capturing(.failed(let message)): "ошибка: \(message)"
        case .waitingForSource: "жду запуска источника"
        case .rebuilding(let attempt): "пересборка сторожем нулей, попытка \(attempt)"
        case .suspended: "приостановлен в тишине"
        }
    }

    private static func describe(_ status: AudioCapturePermission.Status) -> String {
        switch status {
        case .authorized: "разрешено"
        case .denied: "запрещено"
        case .unknown: "неизвестно"
        }
    }
}
