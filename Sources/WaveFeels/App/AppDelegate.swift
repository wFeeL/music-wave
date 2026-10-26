import AppKit
import CoreAudio
import WaveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var arguments = LaunchArguments()
    private(set) var model: AppModel?
    private(set) var windows: WindowsController?
    private(set) var notch: NotchWindowController?
    /// Модель для меню строки меню.
    let modelHolder = AppModelHolder()
    /// «Настройки…» или «Диагностика…» нажаты до готовности модели: окно откроется сразу после
    /// запуска модели.
    private var settingsRequested = false
    private var diagnosticsRequested = false
    /// Сон и пробуждение системы и экранов (`NSWorkspace`). Блокировка экрана подписана через селекторы
    /// (`subscribedToScreenLock`).
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var subscribedToScreenLock = false

    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    func applicationDidFinishLaunching(_ notification: Notification) {
        arguments = LaunchArguments.parse(ProcessInfo.processInfo.arguments)

        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let line = "WaveFeels \(AppModel.versionDescription), macOS \(system), подпись: \(SigningInfo.current())"
        Log.app.info("\(line, privacy: .public)")
        Log.file(line)

        if let seconds = arguments.exitAfter {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                Log.file("выход по --exit-after")
                Log.flush()
                NSApp.terminate(nil)
            }
        }

        let arguments = self.arguments
        if let directory = arguments.snapshotDirectory {
            Task { @MainActor in
                await Self.warmUpCoreAudio()
                await Self.renderSnapshots(to: directory)
            }
            return
        }
        Task { @MainActor in
            // Модель читает свойства Core Audio в главном потоке. Первое обращение к HAL
            // процесса может идти секундами, поэтому оно делается заранее вне главного потока.
            await Self.warmUpCoreAudio()
            let benchmarkDefaults = Self.suiteDefaults(named: arguments.settingsSuite)
            let model = AppModel(defaults: benchmarkDefaults ?? .standard)
            let windows = WindowsController(model: model)
            let notch = NotchWindowController(model: model, arguments: arguments)
            self.model = model
            self.windows = windows
            self.notch = notch
            self.modelHolder.model = model
            model.start(arguments: arguments)
            self.subscribeToSystemEvents()
            notch.show()
            // После `show()`: у панели уже есть раскладка, по ней видно, какое крыло рисуется.
            if let suite = arguments.settingsSuite, benchmarkDefaults != nil {
                Self.logSettings(model.settings, suite: suite, layout: notch.layout)
            }
            if self.settingsRequested {
                self.settingsRequested = false
                windows.showSettings()
            }
            if self.diagnosticsRequested {
                self.diagnosticsRequested = false
                windows.showDiagnostics()
            }
        }
    }

    /// Снимает подписки, останавливает панель (мониторы курсора, таймер опроса, слежение за
    /// полноэкранными окнами) и модель: цикл, задачи, tap с агрегатным устройством (удаление
    /// ждется не дольше 2 с) и процессы perl адаптера.
    func applicationWillTerminate(_ notification: Notification) {
        unsubscribeFromSystemEvents()
        notch?.stop()
        model?.stop()
        Log.file("выход: захват, адаптер и подписки остановлены")
        Log.flush()
    }

    func showSettings() {
        if let windows {
            windows.showSettings()
        } else {
            settingsRequested = true
            Log.file("настройки откроются после запуска модели")
        }
    }

    func showDiagnostics() {
        if let windows {
            windows.showDiagnostics()
        } else {
            diagnosticsRequested = true
            Log.file("диагностика откроется после запуска модели")
        }
    }

    // MARK: - Сон, пробуждение и блокировка экрана

    private func subscribeToSystemEvents() {
        if workspaceObservers.isEmpty {
            let workspace = NSWorkspace.shared.notificationCenter
            workspaceObservers = [
                workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.model?.systemWillSleep()
                    }
                },
                workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.model?.systemDidWake()
                    }
                },
                workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.model?.screensSleepChanged(true)
                    }
                },
                workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.model?.screensSleepChanged(false)
                    }
                },
            ]
        }
        if !subscribedToScreenLock {
            subscribedToScreenLock = true
            // `.deliverImmediately`: иначе, пока приложение неактивно (а после закрытия настроек
            // оно неактивно почти всегда), распределенные уведомления копятся и
            // `screenLocked` может застрять.
            let distributed = DistributedNotificationCenter.default()
            distributed.addObserver(
                self,
                selector: #selector(screenDidLock(_:)),
                name: Self.screenLockedNotification,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
            distributed.addObserver(
                self,
                selector: #selector(screenDidUnlock(_:)),
                name: Self.screenUnlockedNotification,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
    }

    private func unsubscribeFromSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
        workspaceObservers = []
        if subscribedToScreenLock {
            subscribedToScreenLock = false
            let distributed = DistributedNotificationCenter.default()
            distributed.removeObserver(self, name: Self.screenLockedNotification, object: nil)
            distributed.removeObserver(self, name: Self.screenUnlockedNotification, object: nil)
        }
    }

    /// Уведомления приходят через Objective-C: метод не привязан к актору и передает событие
    /// на главную очередь в порядке прихода.
    @objc nonisolated private func screenDidLock(_ notification: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.model?.screenLockChanged(true)
            }
        }
    }

    @objc nonisolated private func screenDidUnlock(_ notification: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.model?.screenLockChanged(false)
            }
        }
    }

    /// `--render-snapshots`: снимки острова в каталог и выход; при ошибке код выхода 1.
    private static func renderSnapshots(to directory: URL) async {
        do {
            let urls = try await SnapshotRenderer.renderAll(to: directory)
            Self.log("снимков записано: \(urls.count) в \(directory.path(percentEncoded: false))")
            Log.flush()
            NSApp.terminate(nil)
        } catch {
            Self.log("снимки не получились: \(error)")
            Log.flush()
            exit(1)
        }
    }

    /// `--settings-suite`: все настройки модели (`AppSettings`, кэш проверки адаптера, история
    /// источников Now Playing) берутся из отдельного набора `UserDefaults`, настройки пользователя
    /// не читаются и не меняются. `nil` без флага и для имени, которое `UserDefaults` не
    /// принимает: тогда модель берет `.standard`. Во втором случае в лог идет только строка
    /// «набор настроек ... недоступен», строки «настройки из набора» нет, и cpu-probe.sh
    /// отбракует замер.
    private static func suiteDefaults(named suite: String?) -> UserDefaults? {
        guard let suite else { return nil }
        guard let defaults = UserDefaults(suiteName: suite) else {
            let line = "набор настроек \(suite) недоступен, используются настройки пользователя"
            Log.app.error("\(line, privacy: .public)")
            Log.file(line)
            return nil
        }
        return defaults
    }

    /// Действующие настройки вида из набора `--settings-suite` (после ограничения диапазонов,
    /// стиль словом `WaveLook.rawValue`, как в `cpu-probe.sh --style`) и то, что еще меняет
    /// нагрузку: крыло, которое рисуется на самом деле (по раскладке панели, не шире предела
    /// экрана; у капсулы без выреза крыльев нет), режим энергосбережения (30 кадров в секунду)
    /// и «Уменьшение движения» (без «вздоха», пульса и свечения). По этой строке cpu-probe.sh
    /// проверяет, на чем шел замер, и переносит ее в шапку отчета.
    private static func logSettings(_ settings: AppSettings, suite: String, layout: NotchLayout?) {
        func number(_ value: Double) -> String { String(format: "%g", value) }
        func yesNo(_ value: Bool) -> String { value ? "да" : "нет" }
        let drawnWing: String
        if let layout {
            let island = layout.collapsedIsland(wingWidth: layout.wingWidth)
            let wing = Double((island.width - layout.notch.width) / 2)
            let kind = layout.hasNotch ? "предел экрана" : "капсула без выреза, предел"
            drawnWing = "\(number(wing)) pt (\(kind) \(number(Double(layout.wingLimit))) pt)"
        } else {
            drawnWing = "неизвестно, экрана нет"
        }
        let values: [String] = [
            "стиль \(settings.look.rawValue)",
            "линий \(settings.lineCount)",
            "заливка \(number(settings.fill))",
            "размер свечения \(number(settings.glowSize))",
            "четкость свечения \(number(settings.glowSharpness))",
            "длительность вспышки \(number(settings.flashLength))",
            "свечение \(number(settings.glowIntensity))",
            "крылья \(number(settings.wingWidth)) pt",
            "рисуется крыло \(drawnWing)",
            "толщина \(number(settings.lineThickness))",
            "амплитуда \(number(settings.waveAmplitude))",
            "переливание \(number(settings.colorFlow))",
            "цвет по частотам \(yesNo(settings.colorByBand))",
            "след пиков \(yesNo(settings.spectrumPeaks))",
            "вздох \(yesNo(settings.beatPulse))",
            "мягкий пульс \(yesNo(settings.softPulse))",
            "пауза \(yesNo(settings.paused))",
            "энергосбережение \(yesNo(ProcessInfo.processInfo.isLowPowerModeEnabled))",
            "уменьшение движения \(yesNo(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))",
        ]
        let line = "настройки из набора \(suite): " + values.joined(separator: ", ")
        Log.app.info("\(line, privacy: .public)")
        Log.file(line)
    }

    /// Первое чтение свойства HAL на фоновом потоке, с записью в лог до и после.
    private static func warmUpCoreAudio() async {
        Self.log("первое обращение к Core Audio")
        let seconds = await Task.detached(priority: .userInitiated) { () -> Double in
            let clock = ContinuousClock()
            let start = clock.now
            let _: AudioObjectID = CAProperty.read(
                CAProperty.systemObject,
                kAudioHardwarePropertyDefaultOutputDevice,
                default: kAudioObjectUnknown
            )
            let elapsed = clock.now - start
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }.value
        Self.log("первое обращение к Core Audio заняло \(String(format: "%.3f", seconds)) с")
    }

    private static func log(_ message: String) {
        Log.audio.info("\(message, privacy: .public)")
        Log.file(message)
    }
}
