import AppKit
import Observation
import QuartzCore
import UniformTypeIdentifiers
import WaveCore

/// Цвет палитры из WaveCore. В SDK macOS есть одноименная структура QuickDraw `RGBColor`
/// (ApplicationServices), поэтому в приложении цвет называется только так.
typealias PaletteColor = WaveCore.RGBColor

/// Связывает настройки, захват звука, Now Playing и состояние острова.
///
/// Цикл 10 Гц на главном акторе: уровень из `FrameStore` идет в `ActivityGate`, Now Playing
/// источника в `IslandInputs`, затем `IslandStateMachine`. Там же настройки и то, скрыт ли
/// остров (тогда анализ идет реже), передаются в `AudioPipeline`. После 10 с тишины захват
/// приостанавливается, только если Now Playing работает и с выбора источника хотя бы раз
/// прислал его трек (`IdleCapturePolicy`); пока захват стоит, конвейер сам следит, не начал ли
/// источник выводить звук. Если источник звучит 2 минуты, а Now Playing о нем молчит, адаптер
/// считается неработающим («тишина адаптера», `AdapterSilenceMonitor`). Сон останавливает захват
/// и адаптер, пробуждение через 1 с запускает их заново (`systemWillSleep`, `systemDidWake`,
/// подписки в `AppDelegate`).
/// Подписок и задач в `deinit` нет: владелец вызывает `stop()`.
@MainActor
@Observable
final class AppModel {
    static let tickInterval: Duration = .milliseconds(100)
    static let logTailLines = 200
    static let privacyAudioCaptureURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    static let privacyScreenCaptureURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    /// Самый длинный шаг анимации острова между кадрами, с.
    static let maxVisualStep = 0.1
    /// Сколько последних интервалов отрисовки дают `renderPeriod`.
    static let renderPeriodSamples = 60
    /// Пределы `renderPeriod`, с: от ProMotion 120 Гц до энергосбережения 30 Гц.
    static let renderPeriodRange = (1.0 / 120)...(1.0 / 30)
    /// На сколько раньше доли «вздох» получает ее свечение при захвате ритма, с: время пружины
    /// `BeatPulse` до пика (`beat-sync.md` 2.8).
    nonisolated static let breathLead = 0.05
    /// Как часто строка «Раскрытый» из «Отрисовки» пишется в файл лога, пока остров раскрыт, с.
    static let renderLogInterval = 10.0
    /// Сколько трек может быть без обложки, прежде чем панель и волны вернутся к стандартной
    /// палитре: адаптер иногда присылает обложку следом за названием.
    static let missingArtworkGrace: Duration = .milliseconds(500)
    /// Пауза после пробуждения перед запуском захвата и адаптера: устройства вывода и coreaudiod
    /// приходят в себя не сразу.
    static let wakeDelay: Duration = .seconds(1)
    /// Как часто перечитывать доступ к звуку, пока показана подсказка и окна ее не опрашивают.
    static let permissionPollInterval = 5.0
    /// Приложения запускаются и закрываются пачкой: `/Applications` просматривается один раз
    /// через столько после последнего события.
    static let applicationsScanDelay: Duration = .milliseconds(500)
    /// Сколько `stop()` ждет удаления tap и агрегата при выходе.
    static let captureTeardownTimeout = 2.0

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
    /// Доступ к звуку разрешен, но быстрые попытки восстановить захват не помогли (сторож нулей
    /// или создание tap): звук не приходит, конвейер повторяет попытки раз в 30 с. Значок в
    /// строке меню с восклицательным знаком, в диагностике пояснение. Снимается, когда звук
    /// вернулся или сменился источник.
    private(set) var captureStallHint = false
    /// Последний результат `AudioCapturePermission.preflight()`.
    private(set) var permissionStatus: AudioCapturePermission.Status = .unknown
    /// Источник, когда пользователь его не выбрал (`settings.source == nil`). Определяется при
    /// каждом запуске и при запуске или закрытии приложений, даже если источник выбран: его
    /// показывают настройки («По умолчанию (...)»). В настройки не пишется.
    private(set) var defaultSource: AudioSource = .systemWide
    /// Курсор в зоне наведения у выреза. Пишет `NotchWindowController` через
    /// `setPointerInHoverZone(_:)`.
    private(set) var pointerInHoverZone = false
    var fullscreenSuppressed = false
    var screenLocked = false
    /// Экраны спят (`NSWorkspace.screensDidSleepNotification`): остров не виден, анализ идет
    /// с частотой скрытого острова, даже если музыка играет.
    private(set) var screensAsleep = false
    /// Режим энергосбережения: остров рисуется не чаще 30 кадров в секунду.
    var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Фазы волн. Сдвигаются на каждом кадре отрисовки, поэтому не наблюдаются.
    @ObservationIgnored var motion = WaveMotion()
    /// Период кадра экрана острова, с (`1 / NSScreen.maximumFramesPerSecond`). Ставит
    /// `NotchWindowController.relayout()`.
    @ObservationIgnored var refreshPeriod = 1.0 / 60
    /// Период отрисовки R, с: медиана последних 60 интервалов кадров в пределах 1/120...1/30
    /// (энергосбережение 30 Гц, ProMotion), до 60 кадров `refreshPeriod`.
    var renderPeriod: Double {
        guard let median = renderPacing.medianInterval(last: Self.renderPeriodSamples), median.isFinite else {
            return refreshPeriod
        }
        return min(max(median, Self.renderPeriodRange.lowerBound), Self.renderPeriodRange.upperBound)
    }
    /// Когда последний раз сменился `islandState`, секунды хоста (`CACurrentMediaTime()`).
    @ObservationIgnored private(set) var islandStateChangedAt: Double = 0
    /// Снимки: кадр, пружины и «вздох» заданы `showPreview` и на кадрах не меняются.
    /// `start(arguments:)` снимает флаг.
    @ObservationIgnored private(set) var previewing = false

    @ObservationIgnored private(set) var arguments = LaunchArguments()
    @ObservationIgnored private var gate = ActivityGate()
    @ObservationIgnored private var machine = IslandStateMachine()
    /// Входы машины острова с последнего обновления: по ним остров пересчитывается сразу, когда
    /// курсор входит в зону или выходит из нее, и в срок `IslandStateMachine.pointerDeadline`.
    @ObservationIgnored private var islandInputs: IslandInputs?
    /// Обновление острова в срок `pointerDeadline`, чтобы раскрытие и сворачивание не ждали тика.
    @ObservationIgnored private var pointerTask: Task<Void, Never>?
    @ObservationIgnored private var pointerTaskDeadline: Double?
    /// Вызывается, когда меняется `islandState`: окно у выреза пересчитывает клики и опрос курсора.
    @ObservationIgnored var onIslandStateChange: (@MainActor () -> Void)?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var appObservers: [any NSObjectProtocol] = []
    /// Первый `checkAudioPermission()` после запуска только запоминает статус.
    @ObservationIgnored private var permissionChecked = false
    /// `defaultSource` надо определить заново: запуск, запуск или закрытие приложения.
    @ObservationIgnored private var defaultSourceStale = true
    /// Тесты: свой поиск источника по умолчанию вместо `resolveDefaultSource()`.
    @ObservationIgnored var defaultSourceResolver: (@MainActor () -> AudioSource)?
    @ObservationIgnored private var appliedSource: AudioSource?
    @ObservationIgnored private var sourceAppRunning = false
    /// Когда остановить IOProc в тишине (через 10 с) и когда вернуть.
    @ObservationIgnored private var idlePolicy = IdleCapturePolicy()
    /// С выбора источника (и с последнего пробуждения) Now Playing хотя бы раз прислал его трек.
    @ObservationIgnored private var sourceTrackSeen = false
    @ObservationIgnored private var adapterSilence = AdapterSilenceMonitor()
    /// Приложения, о которых Now Playing хоть раз сообщал, за все запуски.
    let nowPlayingSources: NowPlayingSourceHistory
    @ObservationIgnored private var recoveryExhausted = false
    @ObservationIgnored private var cachedSigning: String?
    /// Пружина «вздоха» и свечение доли с памятью о вспышках прошлых кадров.
    @ObservationIgnored private var pulse = BeatPulse()
    @ObservationIgnored private var glowState = BeatGlow()
    /// Снимки: свечение и «вздох», заданные `showPreview`.
    @ObservationIgnored private var previewGlow: Float = 0
    @ObservationIgnored private var previewPulse: Float = 0
    @ObservationIgnored private var paletteFade = PaletteFade(palette: PaletteExtractor.fallback)
    @ObservationIgnored private var lastVisualTime: Double?
    /// Пружины уровней трех слоев (по `WaveLayer.rawValue`) и общего уровня на кадрах отрисовки.
    @ObservationIgnored private var layerSprings = [LevelSpring](repeating: LevelSpring(), count: WaveLayer.allCases.count)
    @ObservationIgnored private var levelSpring = LevelSpring()
    /// Замер отрисовки для раздела «Отрисовка».
    @ObservationIgnored private var renderPacing = RenderPacing()
    /// Когда строка «Раскрытый» последний раз ушла в лог; `nil`, пока остров не раскрыт.
    @ObservationIgnored private var lastRenderLog: Double?
    /// Шкала `TimelineView` последнего записанного кадра: SwiftUI пересчитывает сцену и между
    /// тиками, такие пересчеты в замер не идут.
    @ObservationIgnored private var lastRecordedTimeline: Double?
    /// Обложка, из которой получены `artwork` и `palette` (или ждут разбора).
    @ObservationIgnored private var artworkData: Data?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// Номер последнего запроса обложки: ответы старых запросов отбрасываются.
    @ObservationIgnored private var artworkGeneration = 0
    /// Снимки: работает ли Now Playing, вместо `adapter.isAvailable`.
    @ObservationIgnored private var previewNowPlaying: Bool?
    /// `nowPlayingAvailable` на прошлом тике: при смене обложка и палитра пересчитываются.
    @ObservationIgnored private var artworkNowPlaying = false
    /// Обложка, из которой сейчас получены `artwork` и `palette` (`nil`: стандартная палитра).
    @ObservationIgnored private var shownArtworkData: Data?
    /// Значок приложения-источника для панели без трека, по пути бандла.
    @ObservationIgnored private var sourceIconCache: (path: String, icon: NSImage)?
    /// Последний просмотр `/Applications`: Яндекс Музыка по имени бандла или `nil`. Первый раз
    /// при запуске, дальше вне главного потока после запуска или закрытия приложений.
    @ObservationIgnored private var scannedYandexMusic: AudioSource?
    @ObservationIgnored private var applicationsScanned = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Когда последний раз читался доступ к звуку (`checkAudioPermission`), по `systemUptime`.
    @ObservationIgnored private var lastPermissionCheck = -Double.infinity
    /// Между `systemWillSleep` и запуском после пробуждения.
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var wakeTask: Task<Void, Never>?

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
        nowPlayingSources = NowPlayingSourceHistory(defaults: defaults)
    }

    // MARK: - Запуск и остановка

    /// `--demo`: звук из файла; `--no-capture`: без tap и без адаптера; иначе обычный захват.
    func start(arguments: LaunchArguments) {
        guard loopTask == nil else { return }
        self.arguments = arguments
        previewing = false

        applySettings()
        subscribeToNotifications()
        refreshSourceAppRunning()

        if arguments.noCapture {
            log("захват звука выключен (--no-capture)")
        }
        startSources()
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
        wakeTask?.cancel()
        wakeTask = nil
        asleep = false
        pointerTask?.cancel()
        pointerTask = nil
        pointerTaskDeadline = nil
        islandInputs = nil
        scanTask?.cancel()
        scanTask = nil
        stopSources()
        pipeline.waitForCaptureTeardown(timeout: Self.captureTeardownTimeout)
        artworkTask?.cancel()
        artworkTask = nil
    }

    /// Захват или демо по аргументам запуска и адаптер Now Playing.
    private func startSources() {
        if let file = arguments.demoFile {
            do {
                try pipeline.startDemo(file: file)
            } catch {
                log("демо не запустилось: \(error.localizedDescription)")
            }
        } else if !arguments.noCapture {
            pipeline.start()
        }
        if !arguments.noCapture {
            adapter.start()
        }
    }

    /// Захват, демо, анализ и процессы адаптера останавливаются; агрегатное устройство
    /// удаляется в очереди управления, главный поток этого не ждет.
    private func stopSources() {
        pipeline.stop()
        adapter.stop()
        idlePolicy.reset()
    }

    // MARK: - Сон и блокировка экрана

    /// `NSWorkspace.willSleepNotification`: захват и адаптер стоят до пробуждения.
    func systemWillSleep() {
        wakeTask?.cancel()
        wakeTask = nil
        guard loopTask != nil, !asleep else { return }
        asleep = true
        log("сон: захват и Now Playing остановлены")
        pipeline.stopForSleep()
        adapter.stop()
        idlePolicy.reset()
    }

    /// `NSWorkspace.didWakeNotification`: через `wakeDelay` возвращается режим до сна (захват
    /// с новым tap, демо с тем же файлом, без захвата, пауза) и адаптер запускается заново:
    /// устройство вывода и процессы за время сна могли смениться. Пробуждение без замеченного
    /// сна тоже пересобирает все.
    func systemDidWake() {
        guard loopTask != nil else { return }
        wakeTask?.cancel()
        log("пробуждение: захват и Now Playing запустятся через \(Self.wakeDelay.components.seconds) с")
        wakeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.wakeDelay)
            } catch {
                return
            }
            guard let self else { return }
            self.wakeTask = nil
            self.finishWake()
        }
    }

    private func finishWake() {
        guard loopTask != nil else { return }
        if !asleep {
            adapter.stop()
        }
        asleep = false
        idlePolicy.reset()
        // Адаптер перезапускается: его проверка и «тишина адаптера» начинаются заново.
        sourceTrackSeen = false
        adapterSilence.reset()
        defaultSourceStale = true
        applySettings()
        refreshSourceAppRunning()
        pipeline.restartAfterSleep()
        if !arguments.noCapture {
            adapter.start()
        }
        checkAudioPermission()
        log("после пробуждения захват и Now Playing запущены")
    }

    /// `com.apple.screenIsLocked` и `com.apple.screenIsUnlocked`: на заблокированном экране
    /// остров скрыт (`IslandInputs.userPaused`) и на курсор не отвечает.
    func screenLockChanged(_ locked: Bool) {
        guard locked != screenLocked else { return }
        screenLocked = locked
        log(locked ? "экран заблокирован: остров скрыт" : "экран разблокирован")
    }

    /// Остров принудительно скрыт и на курсор не отвечает: пауза, блокировка экрана или
    /// полноэкранное окно при включенной настройке.
    var islandSuppressed: Bool {
        settings.paused || screenLocked || (fullscreenSuppressed && settings.hideInFullscreen)
    }

    /// `NSWorkspace.screensDidSleepNotification` и `screensDidWakeNotification`: пока экраны
    /// спят, остров никто не видит (`TimelineView` не рисует), и анализ идет реже, как при
    /// скрытом острове. Применяется сразу.
    func screensSleepChanged(_ asleep: Bool) {
        guard asleep != screensAsleep else { return }
        screensAsleep = asleep
        log(asleep ? "экраны уснули: анализ реже" : "экраны проснулись")
        updateAnalysisRate()
    }

    /// Анализ реже (15 Гц), когда остров скрыт или экраны спят.
    private func updateAnalysisRate() {
        pipeline.islandHidden = islandState == .hidden || screensAsleep
    }

    /// «Приостановить визуализацию» и «Возобновить визуализацию»: на паузе захват и анализ
    /// остановлены, остров скрыт и не рисуется. Применяется сразу, не дожидаясь тика.
    func setPaused(_ paused: Bool) {
        guard paused != settings.paused else { return }
        settings.paused = paused
        idlePolicy.reset()
        log(paused ? "визуализация приостановлена" : "визуализация возобновлена")
        applySettings()
    }

    // MARK: - Источник по умолчанию

    /// Источник, который сейчас используется: выбранный пользователем или по умолчанию.
    var effectiveSource: AudioSource {
        settings.source ?? defaultSource
    }

    private func refreshDefaultSource() {
        defaultSourceStale = false
        let source = defaultSourceResolver?() ?? resolveDefaultSource()
        if source != defaultSource {
            defaultSource = source
            log("источник по умолчанию: \(source.displayName)")
        }
    }

    /// Яндекс Музыка по bundle ID, иначе приложение в `/Applications` с «Яндекс Музыка» или
    /// «Yandex Music» в имени, иначе весь звук системы. Каталог берется из последнего просмотра
    /// (`scheduleApplicationsScan`); синхронно он читается только при первом вызове.
    func resolveDefaultSource() -> AudioSource {
        let workspace = NSWorkspace.shared
        for bundleID in ProcessMatcher.yandexMusicCandidates {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return Self.applicationSource(at: url, fallbackBundleID: bundleID)
            }
        }
        if !applicationsScanned {
            applicationsScanned = true
            scannedYandexMusic = Self.scanApplicationsFolder()
        }
        return scannedYandexMusic ?? .systemWide
    }

    /// Приложение в `/Applications` с «Яндекс Музыка» или «Yandex Music» в имени.
    /// Читает каталог, поэтому после запуска вызывается вне главного потока.
    nonisolated static func scanApplicationsFolder() -> AudioSource? {
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
                return applicationSource(at: url, fallbackBundleID: nil)
            }
        }
        return nil
    }

    /// Просмотр `/Applications` вне главного потока через `applicationsScanDelay` после
    /// последнего запуска или закрытия приложения; если результат изменился, источник по
    /// умолчанию определяется заново.
    private func scheduleApplicationsScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.applicationsScanDelay)
            } catch {
                return
            }
            let found = await Task.detached(priority: .utility) {
                AppModel.scanApplicationsFolder()
            }.value
            guard let self, !Task.isCancelled else { return }
            self.scanTask = nil
            self.applicationsScanned = true
            guard found != self.scannedYandexMusic else { return }
            self.scannedYandexMusic = found
            self.defaultSourceStale = true
            self.applySettings()
        }
    }

    /// Источник-приложение по пути бандла: путь без символических ссылок, имя из бандла.
    nonisolated static func applicationSource(at url: URL, fallbackBundleID: String?) -> AudioSource {
        let path = AudioProcessList.canonicalPath(url)
        let bundle = Bundle(path: path)
        let bundleID = bundle?.bundleIdentifier ?? fallbackBundleID ?? ""
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: path)
        return .application(bundleID: bundleID, bundlePath: path, displayName: name)
    }

    /// Now Playing относится к источнику: bundle ID приложения или его родителя совпал или
    /// начинается с bundle ID источника и точки, как у процессов (`ProcessMatcher`).
    /// Для всего звука системы подходит любой.
    nonisolated static func belongs(_ info: NowPlayingInfo, to source: AudioSource) -> Bool {
        info.belongs(to: source)
    }

    // MARK: - Доступ к звуку

    /// Перечитывает статус доступа и пересчитывает `permissionHint`.
    /// Если доступ стал разрешенным (не при первой проверке), счетчик сторожа нулей
    /// сбрасывается и tap пересобирается.
    func checkAudioPermission() {
        lastPermissionCheck = ProcessInfo.processInfo.systemUptime
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

    /// Подсказки о доступе и о захвате, который не восстанавливается (`CaptureHints`).
    private func updatePermissionHint() {
        let exhausted = pipeline.recoveryExhausted
        if exhausted != recoveryExhausted {
            recoveryExhausted = exhausted
            // Быстрые попытки кончились: стоит заново спросить TCC, вдруг доступ отозвали.
            if exhausted {
                applyPermissionStatus(AudioCapturePermission.preflight())
            }
        }
        let hints = CaptureHints(access: Self.access(permissionStatus), recoveryExhausted: exhausted)
        if hints.permission != permissionHint {
            permissionHint = hints.permission
            log(hints.permission ? "подсказка о доступе к звуку показана" : "подсказка о доступе к звуку снята")
        }
        if hints.stalled != captureStallHint {
            captureStallHint = hints.stalled
            log(hints.stalled
                ? "подсказка показана: звук не приходит, хотя доступ разрешен, захват повторяется"
                : "подсказка о захвате без звука снята")
        }
    }

    nonisolated static func access(_ status: AudioCapturePermission.Status) -> CaptureAccess {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .unknown: .unknown
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
        if sourceInfo != nil {
            sourceTrackSeen = true
            if case .application(let bundleID, _, _) = source {
                nowPlayingSources.insert(bundleID)
            }
            adapter.clearSilence()
        }
        if let sourceInfo, sourceInfo != lastTrack {
            lastTrack = sourceInfo
            updateArtwork()
        } else if nowPlayingAvailable != artworkNowPlaying {
            updateArtwork()
        }

        pipeline.adapterAvailable = adapter.isAvailable
        pipeline.adapterSaysPlaying = sourcePlaying

        let audioActive = gate.update(levelDB: store.latest.rawLevelDB, now: now)
        if !settings.paused {
            manageIdleCapture(audioActive: audioActive, sourcePlaying: sourcePlaying, now: now)
        }
        watchAdapterSilence(audioActive: audioActive, now: now)

        let inputs = IslandInputs(
            audioActive: audioActive,
            sourcePlaying: sourcePlaying,
            sourceRunning: source == .systemWide ? info != nil : sourceAppRunning,
            hasLastTrack: lastTrack != nil,
            pointerInHoverZone: pointerInHoverZone,
            fullscreenSuppressed: fullscreenSuppressed && settings.hideInFullscreen,
            userPaused: settings.paused || screenLocked
        )
        updateIsland(inputs, now: now)
        updatePermissionHint()
        // Подсказка показана, а окна, которые опрашивают доступ каждую секунду, закрыты:
        // пользователь мог выдать доступ в Системных настройках, не возвращаясь в приложение.
        if permissionHint, now - lastPermissionCheck >= Self.permissionPollInterval {
            checkAudioPermission()
        }
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        if low != lowPower {
            lowPower = low
        }
    }

    /// Курсор вошел в зону выреза или вышел из нее: остров пересчитывается сразу, а не в
    /// следующем тике, и раскрытие наступает через 150 мс, сворачивание через 300 мс
    /// (`IslandStateMachine`), а не на тик позже.
    func setPointerInHoverZone(_ inside: Bool) {
        guard inside != pointerInHoverZone else { return }
        pointerInHoverZone = inside
        guard loopTask != nil, var inputs = islandInputs else { return }
        inputs.pointerInHoverZone = inside
        updateIsland(inputs, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Машина острова по входам `inputs`; при смене состояния лог и `onIslandStateChange`.
    private func updateIsland(_ inputs: IslandInputs, now: Double) {
        islandInputs = inputs
        machine.hideDelay = settings.hideDelay
        let state = machine.update(inputs, now: now)
        if state != islandState {
            // По этой строке замер CPU в CI убеждается, что остров действительно показан.
            log("остров: \(Self.describe(islandState)) -> \(Self.describe(state))")
            islandState = state
            islandStateChangedAt = CACurrentMediaTime()
            onIslandStateChange?()
        }
        updateAnalysisRate()
        schedulePointerDeadline(now: now)
    }

    /// Ставит обновление острова на срок `IslandStateMachine.pointerDeadline`, если он есть
    /// и еще не поставлен.
    private func schedulePointerDeadline(now: Double) {
        let deadline = machine.pointerDeadline
        guard deadline != pointerTaskDeadline else { return }
        pointerTask?.cancel()
        pointerTask = nil
        pointerTaskDeadline = deadline
        guard let deadline else { return }
        let wait = max(0, deadline - now)
        pointerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                return
            }
            guard let self else { return }
            self.pointerTask = nil
            self.pointerTaskDeadline = nil
            guard self.loopTask != nil, let inputs = self.islandInputs else { return }
            self.updateIsland(inputs, now: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Настройки пользователя в `AudioPipeline`. Свойства конвейера сами отбрасывают
    /// повторы, `LevelSettings` сравнивается здесь, чтобы не будить анализ каждый тик.
    private func applySettings() {
        if defaultSourceStale {
            refreshDefaultSource()
        }
        let source = effectiveSource
        if source != appliedSource {
            appliedSource = source
            sourceTrackSeen = false
            adapterSilence.reset()
            // «Тишина адаптера» относилась к прежнему источнику.
            adapter.clearSilence()
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
        pipeline.syncOffsetMs = settings.syncOffsetMs
        pipeline.paused = settings.paused
    }

    /// После 10 с тишины IOProc останавливается, но только у приложения, о котором Now Playing
    /// с выбора источника хотя бы раз прислал трек, и пока ни один его процесс не выводит звук:
    /// иначе о начале музыки узнает лишь tap (Telegram, игры, весь звук системы). Возобновление
    /// по звуку, по старту воспроизведения, когда приостановка перестала быть оправданной, а еще
    /// сам конвейер возобновляет захват, когда процесс источника начал выводить звук
    /// (`AudioPipeline.suspendIdle()`).
    private func manageIdleCapture(audioActive: Bool, sourcePlaying: Bool, now: Double) {
        let source = effectiveSource
        let systemWide = source == .systemWide
        // Флаг вывода читается, только когда он может что-то решить (приостановить захват можно
        // лишь при работающем Now Playing, приславшем трек источника). В приостановке конвейер
        // берет его из подписок, без опроса HAL.
        let outputting = !systemWide && !audioActive && !sourcePlaying
            && adapter.isAvailable && sourceTrackSeen
            && pipeline.sourceProcessOutputting()
        let inputs = IdleCapturePolicy.Inputs(
            audioActive: audioActive,
            sourcePlaying: sourcePlaying,
            adapterAvailable: adapter.isAvailable,
            sourceReportsNowPlaying: sourceTrackSeen,
            systemWide: systemWide,
            sourceOutputting: outputting,
            suspended: pipeline.status == .suspended
        )
        switch idlePolicy.update(inputs, now: now) {
        case .none:
            break
        case .suspend:
            pipeline.suspendIdle()
        case .resume:
            pipeline.resume()
        }
    }

    /// «Тишина адаптера»: приложение-источник, о котором Now Playing раньше сообщал, по tap
    /// звучит 2 минуты, а Now Playing ни разу не прислал его трек. Адаптер помечается
    /// неработающим, приложение переходит в запасной режим; трек источника, смена источника,
    /// пробуждение или перезапуск приложения возвращают его. Для всего звука системы и в демо
    /// не считается.
    private func watchAdapterSilence(audioActive: Bool, now: Double) {
        guard arguments.demoFile == nil else { return }
        let applies = AdapterSilenceMonitor.applies(
            to: effectiveSource,
            reportedBundleIDs: nowPlayingSources.bundleIDs
        )
        let silent = adapterSilence.update(
            sourceAudible: audioActive,
            trackSeen: sourceTrackSeen,
            adapterAvailable: adapter.isAvailable && applies,
            now: now
        )
        guard silent else { return }
        log("тишина адаптера: источник \(effectiveSource.displayName) звучит \(Int(adapterSilence.limit)) с без данных Now Playing")
        adapter.markSilent()
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

    /// Запуск или закрытие приложения: `sourceRunning` и источник по умолчанию пересчитываются
    /// сразу по bundle ID, каталог `/Applications` просматривается позже вне главного потока.
    private func applicationsChanged() {
        defaultSourceStale = true
        applySettings()
        refreshSourceAppRunning()
        scheduleApplicationsScan()
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

    /// Трек для панели с прогрессом и кнопками (`ExpandedPanelView`), см. `panelTrack(...)`.
    var panelTrack: NowPlayingInfo? {
        // Снимки задают трек напрямую, адаптер в них не запущен.
        if previewNowPlaying != nil {
            return nowPlayingAvailable ? lastTrack : nil
        }
        return Self.panelTrack(
            lastTrack: lastTrack,
            current: adapter.info,
            source: effectiveSource,
            nowPlayingAvailable: nowPlayingAvailable
        )
    }

    /// Команда кнопки панели. Уходит, только если Now Playing по-прежнему показывает источник:
    /// между отрисовкой и нажатием он мог переключиться на другое приложение.
    func sendPanelCommand(_ command: MediaCommand) {
        guard panelTrack != nil else {
            log("команда \(command.rawValue) не отправлена: Now Playing показывает не источник")
            return
        }
        adapter.send(command)
    }

    /// Панель показывает трек и кнопки, только пока Now Playing работает и его текущая запись
    /// относится к выбранному источнику (`belongs`, те же правила, что у процессов). Кнопки
    /// отправляют команды тому, кого сейчас показывает Now Playing: если он переключился на
    /// другое приложение, а у источника остался прежний трек, команды ушли бы не туда. Тогда
    /// панель показывает источник и «Открыть», как без Now Playing.
    nonisolated static func panelTrack(
        lastTrack: NowPlayingInfo?,
        current: NowPlayingInfo?,
        source: AudioSource,
        nowPlayingAvailable: Bool
    ) -> NowPlayingInfo? {
        guard nowPlayingAvailable, let current, current.belongs(to: source) else { return nil }
        return lastTrack
    }

    /// Обложка, по которой считаются картинка панели и палитра: только пока Now Playing
    /// работает. В запасном режиме обложки нет и палитра стандартная,
    /// даже если `lastTrack` остался с тех пор, когда адаптер работал.
    nonisolated static func artworkSource(track: NowPlayingInfo?, nowPlayingAvailable: Bool) -> Data? {
        nowPlayingAvailable ? track?.artworkData : nil
    }

    /// Обложка сменилась (новый трек или Now Playing начал либо перестал работать): картинка
    /// для панели и палитра считаются вне главного актора, затем палитра плавно перетекает
    /// в новую. Без обложки стандартная палитра наступает через `missingArtworkGrace`: так
    /// нет вспышки, пока адаптер перезапускается или присылает обложку следом за названием.
    /// На паузе `lastTrack` и его обложка остаются. `immediately` (снимки и тесты): то же
    /// самое синхронно и без паузы.
    private func updateArtwork(immediately: Bool = false) {
        let available = nowPlayingAvailable
        artworkNowPlaying = available
        let data = Self.artworkSource(track: lastTrack, nowPlayingAvailable: available)
        guard immediately || data != artworkData else { return }
        artworkData = data
        artworkTask?.cancel()
        artworkTask = nil
        artworkGeneration += 1
        let generation = artworkGeneration
        let pixels = ExpandedPanelView.artworkPixels
        // Вернулись к тому, что уже на экране (например, адаптер быстро перезапустился):
        // ожидание отменено, пересчитывать нечего.
        if !immediately, data == shownArtworkData { return }
        if immediately {
            applyArtwork(data.map { ArtworkAnalysis(data: $0, displayPixels: pixels) }, data: data, generation: generation)
            return
        }
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
            self.applyArtwork(analysis, data: data, generation: generation)
        }
    }

    private func applyArtwork(_ analysis: ArtworkAnalysis?, data: Data?, generation: Int) {
        shownArtworkData = data
        artwork = analysis?.image.map { PanelArtwork(image: $0, id: generation) }
        let target = analysis?.palette ?? PaletteExtractor.fallback
        if target != palette {
            palette = target
        }
        if let analysis, analysis.image == nil {
            log("обложка не прочиталась, палитра стандартная")
        }
    }

    // MARK: - Источник в панели

    /// Значок приложения-источника для панели без трека; у всего звука системы значка нет.
    /// Если приложения по пути нет, значок обычного приложения.
    func sourceIcon() -> NSImage? {
        guard case .application(_, let path, _) = effectiveSource else { return nil }
        if let cached = sourceIconCache, cached.path == path { return cached.icon }
        let workspace = NSWorkspace.shared
        let icon = FileManager.default.fileExists(atPath: path)
            ? workspace.icon(forFile: path)
            : workspace.icon(for: .applicationBundle)
        sourceIconCache = (path, icon)
        return icon
    }

    /// Кнопка «Открыть» в панели без трека: запускает приложение-источник или выводит его вперед.
    func openSource() {
        guard case .application(let bundleID, let path, let name) = effectiveSource else { return }
        var url: URL?
        if FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else if !bundleID.isEmpty {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        guard let url else {
            log("открыть источник не удалось: нет приложения \(name)")
            return
        }
        log("открываю источник: \(name)")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { @Sendable _, error in
            // Вызывается не на главном потоке: замыкание явно @Sendable (без изоляции главного
            // актора), модель не трогает, лог потокобезопасный.
            guard let error else { return }
            let message = "источник \(name) не открылся: \(error.localizedDescription)"
            Log.app.error("\(message, privacy: .public)")
            Log.file(message)
        }
    }

    // MARK: - Кадр острова

    /// Шаг анимации острова на момент `now` (секунды хоста, `CACurrentMediaTime()`).
    ///
    /// Кадр будет на экране в `tP = now + presentationLead(R)`, `R = renderPeriod`: на этот момент
    /// берется кадр анализа, смешанный из соседних (`FrameStore.frame(at:)`), и свечение доли по
    /// расписанию (`BeatGlow`, с памятью о вспышках). Уровни слоев и общий уровень идут через пружины
    /// (`LevelSpring`), фазы волн по сглаженным уровням (при «Уменьшении движения» вдвое медленнее),
    /// затем к басу прибавляется акцент доли (`BeatGlow.accented`), уже после пружин, чтобы он
    /// оставался четким. «Вздох»: при захвате ритма пружина получает свечение на 50 мс раньше, без
    /// захвата равен свечению. «Уменьшение движения»: ни свечения, ни «вздоха», ни акцента.
    /// Шаг ограничен `maxVisualStep`, повторный вызов с тем же `now` ничего не двигает. Кадр идет в
    /// замер отрисовки (`timelineTime`: дата `TimelineView`), пока остров раскрыт, раз в 10 с строка
    /// замера пишется в лог. Снимки (`previewing`) получают заданные кадр, свечение и «вздох» без шага.
    func islandVisuals(now: Double, timelineTime: Double, reduceMotion: Bool) -> IslandVisuals {
        let period = renderPeriod
        let presented = now + LatencyCalculator.presentationLead(refreshPeriod: period)
        let sampled = store.frame(at: presented)
        if previewing {
            let glow = reduceMotion ? 0 : previewGlow
            let frame = springFrame(sampled, glow: glow)
            let shown = paletteFade.palette(target: palette, now: now)
            return IslandVisuals(
                frame: frame, sampled: sampled, motion: motion, palette: shown,
                glow: glow, pulse: reduceMotion ? 0 : previewPulse, time: now
            )
        }
        var dt = 0.0
        if let lastVisualTime, now.isFinite {
            dt = min(max(now - lastVisualTime, 0), Self.maxVisualStep)
        }
        if now.isFinite {
            lastVisualTime = now
        }
        for index in layerSprings.indices {
            let target = index < sampled.layers.count ? sampled.layers[index] : 0
            layerSprings[index].step(toward: target, dt: dt)
        }
        levelSpring.step(toward: sampled.level, dt: dt)
        motion.advance(layers: layerSprings.map(\.value), dt: reduceMotion ? dt / 2 : dt)

        var glow: Float = 0
        var breath: Float = 0
        if !reduceMotion {
            let schedule = store.schedule
            glow = glowState.value(at: presented, schedule: schedule, refreshPeriod: period)
            let early = BeatGlow.value(at: presented + Self.breathLead, schedule: schedule, refreshPeriod: period)
            let spring = pulse.step(beat: early, dt: dt)
            breath = schedule.locked ? spring : glow
        }
        let frame = springFrame(sampled, glow: glow)
        recordRender(now: now, timelineTime: timelineTime)
        let shown = paletteFade.palette(target: palette, now: now)
        return IslandVisuals(
            frame: frame, sampled: sampled, motion: motion, palette: shown, glow: glow, pulse: breath, time: now
        )
    }

    /// Кадр `sampled` с уровнями слоев и общим уровнем из пружин и акцентом доли на басу.
    private func springFrame(_ sampled: WaveFrame, glow: Float) -> WaveFrame {
        var frame = sampled
        frame.layers = BeatGlow.accented(layerSprings.map(\.value), glow: glow)
        frame.level = levelSpring.value
        return frame
    }

    /// Кадр отрисовки в `renderPacing`; пока остров раскрыт, строка «Раскрытый» раз в
    /// `renderLogInterval` в файл лога (первая через 10 с после раскрытия).
    private func recordRender(now: Double, timelineTime: Double) {
        guard timelineTime != lastRecordedTimeline else { return }
        lastRecordedTimeline = timelineTime
        let bucket = RenderBucket.classify(state: islandState, sinceStateChange: now - islandStateChangedAt)
        renderPacing.record(now: now, timelineTime: timelineTime, bucket: bucket, analysisSequence: store.sequence)
        guard islandState == .expanded, now.isFinite else {
            lastRenderLog = nil
            return
        }
        guard let lastRenderLog else {
            self.lastRenderLog = now
            return
        }
        guard now - lastRenderLog >= Self.renderLogInterval else { return }
        self.lastRenderLog = now
        let row = renderPacing.summary(.expanded, refreshPeriod: renderPeriod)?.pacingText ?? Self.noRenderData
        Log.file("отрисовка, раскрытый: \(row)")
    }

    /// Снимки острова: модель не запущена, состояние, трек, палитра и кадр задаются напрямую.
    /// Часы анимации встают на `time`, хранилище кадров держит `frame` в любой момент, пружины
    /// уровней стоят на его значениях, свечение доли `glow` и «вздох» `pulse` возвращаются как
    /// есть, поэтому кадр рисуется без шага анимации, без сглаживания и без перехода палитры
    /// (`previewing`). Остров считается давно пришедшим в `state`.
    /// Обложка трека разбирается здесь же, синхронно, тем же путем, что в работе; палитра
    /// берется из нее же или задается явно (`palette`).
    func showPreview(
        state: IslandState,
        track: NowPlayingInfo?,
        palette: [PaletteColor]?,
        frame: WaveFrame,
        motion: WaveMotion,
        glow: Float,
        pulse: Float,
        time: Double,
        nowPlayingAvailable: Bool = true
    ) {
        islandState = state
        islandStateChangedAt = -Double.infinity
        lastTrack = track
        previewNowPlaying = nowPlayingAvailable
        updateArtwork(immediately: true)
        if let palette {
            self.palette = palette
        }
        store.reset(to: frame)
        for index in layerSprings.indices {
            layerSprings[index].reset(to: index < frame.layers.count ? frame.layers[index] : 0)
        }
        levelSpring.reset(to: frame.level)
        previewing = true
        self.motion = motion
        previewGlow = glow
        previewPulse = pulse
        paletteFade = PaletteFade(palette: self.palette)
        lastVisualTime = time
    }

    /// Снимки окна настроек: подсказка о доступе к звуку без проверки TCC.
    func previewPermissionHint(_ shown: Bool) {
        permissionHint = shown
    }

    private func log(_ message: String) {
        Log.app.info("\(message, privacy: .public)")
        Log.file(message)
    }

    /// Тесты: отложенный запуск после пробуждения, чтобы дождаться его без часов.
    var pendingWakeForTesting: Task<Void, Never>? { wakeTask }
}

/// Обложка в панели. `id` меняется с каждой новой обложкой: по нему панель плавно сменяет картинку.
struct PanelArtwork {
    let image: CGImage
    let id: Int
}

/// Все, что нужно острову на один кадр.
struct IslandVisuals {
    /// Кадр для рисования: уровни слоев и общий уровень после пружин.
    var frame: WaveFrame
    /// Кадр анализа на момент кадра, смешанный из соседних, до пружин.
    var sampled: WaveFrame
    var motion: WaveMotion
    /// Палитра с учетом перехода.
    var palette: [PaletteColor]
    /// Свечение доли 0...1 на момент показа кадра: свечение под островом и точки у выреза.
    var glow: Float
    /// «Вздох» 0...1: масштаб свернутого острова.
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
            renderSection(),
            rhythmSection(),
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
            DiagnosticsRow(label: "Экран заблокирован", value: Self.yesNo(screenLocked)),
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
            label: "Последняя ошибка захвата",
            value: pipeline.lastCaptureError.map {
                "\($0.date.formatted(date: .omitted, time: .standard)): \($0.message)"
            } ?? "нет"
        ))
        let slowRetry = "дальше раз в \(Int(pipeline.recoveryTiming.slowRetryInterval)) с"
        rows.append(DiagnosticsRow(
            label: "Пересборок сторожа нулей",
            value: "\(pipeline.watchdogRebuilds) из \(pipeline.recoveryTiming.maxWatchdogRebuilds)"
                + (pipeline.watchdogRebuilds >= pipeline.recoveryTiming.maxWatchdogRebuilds ? ", \(slowRetry)" : "")
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
        let milliseconds = Self.milliseconds(pipeline.outputLatency)
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

    /// Замер отрисовки по корзинам `RenderBucket`. Пропуски считаются от периода отрисовки
    /// `renderPeriod`, а не экрана: в энергосбережении (30 Гц) и на ProMotion кадр через период
    /// экрана не пропуск. Строка «Экран» показывает наибольшую частоту экрана.
    private func renderSection() -> DiagnosticsSection {
        let period = renderPeriod
        let names = ["свернутый", "раскрытый", "переход"]
        let summaries = [RenderBucket.collapsed, .expanded, .transition].map {
            renderPacing.summary($0, refreshPeriod: period)
        }
        var analysis: [String] = []
        var spread: [String] = []
        for (name, summary) in zip(names, summaries) {
            analysis.append("\(name) (\(summary?.analysisFramesText ?? Self.noRenderData))")
            spread.append("\(name) (\(summary?.spreadText ?? Self.noRenderData))")
        }
        let hertz = Int((1 / refreshPeriod).rounded())
        return DiagnosticsSection(title: "Отрисовка", rows: [
            DiagnosticsRow(label: "Экран", value: "\(hertz) Гц | энергосбережение: \(Self.yesNo(lowPower))"),
            DiagnosticsRow(label: "Свернутый", value: summaries[0]?.pacingText ?? Self.noRenderData),
            DiagnosticsRow(label: "Раскрытый", value: summaries[1]?.pacingText ?? Self.noRenderData),
            DiagnosticsRow(label: "Переход", value: summaries[2]?.pacingText ?? Self.noRenderData),
            DiagnosticsRow(label: "Кадров анализа на кадр", value: analysis.joined(separator: ", ")),
            DiagnosticsRow(label: "Разброс", value: spread.joined(separator: ", ")),
        ])
    }

    /// Темп, уверенность и захват ритма из последнего расписания свечения, задержки, из которых
    /// складывается время свечения, и сдвиг синхронизации.
    private func rhythmSection() -> DiagnosticsSection {
        let schedule = store.schedule
        let tempo = schedule.bpm.flatMap { $0.isFinite ? "\(Int($0.rounded())) BPM" : nil } ?? "нет"
        let lead = LatencyCalculator.presentationLead(refreshPeriod: renderPeriod)
        return DiagnosticsSection(title: "Ритм", rows: [
            DiagnosticsRow(label: "Темп", value: tempo),
            DiagnosticsRow(label: "Уверенность", value: String(format: "%.2f", schedule.confidence)),
            DiagnosticsRow(label: "Захват ритма", value: Self.yesNo(schedule.locked)),
            DiagnosticsRow(label: "Задержка вывода", value: "\(Self.milliseconds(pipeline.outputLatency)) мс"),
            DiagnosticsRow(label: "Задержка показа", value: "\(Self.milliseconds(lead)) мс"),
            DiagnosticsRow(label: "Запаздывание онсета", value: "\(Self.milliseconds(StreamAnalyzer.onsetLag)) мс"),
            DiagnosticsRow(label: "Сдвиг синхронизации", value: Self.syncOffsetText(settings.syncOffsetMs)),
        ])
    }

    /// Секунды в целые миллисекунды; не число дает 0.
    static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int((seconds * 1000).rounded())
    }

    /// «0 мс», «+15 мс», «-20 мс».
    static func syncOffsetText(_ milliseconds: Int) -> String {
        milliseconds > 0 ? "+\(milliseconds) мс" : "\(milliseconds) мс"
    }

    private func permissionSection() -> DiagnosticsSection {
        DiagnosticsSection(title: "Доступ", rows: [
            DiagnosticsRow(label: "Запись системного аудио", value: Self.describe(permissionStatus)),
            DiagnosticsRow(label: "Подсказка о доступе", value: permissionHint ? "показана" : "нет"),
            DiagnosticsRow(
                label: "Звук не приходит",
                value: captureStallHint ? Self.captureStallText : "нет"
            ),
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

    /// В корзине замера отрисовки еще нет кадров.
    static let noRenderData = "нет данных"

    /// Пояснение к `captureStallHint` в диагностике.
    static let captureStallText = "Звук не приходит, хотя доступ разрешен. WaveFeels повторяет попытки."

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
        case .silent: "не работает: тишина адаптера (источник звучит 2 мин, а данных о его треке нет)"
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
        case .starting: "создаю tap"
        case .capturing(.running(_, let processCount)): "захват идет, процессов в tap: \(processCount)"
        case .capturing(.idle): "tap не создан"
        case .capturing(.failed(let message)):
            "ошибка: \(message); повтор раз в \(Int(AudioPipeline.slowRetryInterval)) с"
        case .waitingForSource: "жду запуска источника"
        case .rebuilding(let attempt): "пересборка сторожем нулей, попытка \(attempt)"
        case .retrying(let attempt, let message):
            "tap не создан (\(message)), повтор \(attempt) из \(AudioPipeline.startRetryPauses.count)"
        case .suspended: "приостановлен в тишине"
        case .paused: "остановлен, визуализация на паузе"
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
