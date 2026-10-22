import AppKit
import CoreAudio

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
                Self.renderSnapshots(to: directory)
            }
            return
        }
        Task { @MainActor in
            // Модель читает свойства Core Audio в главном потоке. Первое обращение к HAL
            // процесса может идти секундами, поэтому оно делается заранее вне главного потока.
            await Self.warmUpCoreAudio()
            let model = AppModel()
            let windows = WindowsController(model: model)
            let notch = NotchWindowController(model: model, arguments: arguments)
            self.model = model
            self.windows = windows
            self.notch = notch
            self.modelHolder.model = model
            model.start(arguments: arguments)
            notch.show()
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

    func applicationWillTerminate(_ notification: Notification) {
        notch?.stop()
        model?.stop()
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

    /// `--render-snapshots`: снимки острова в каталог и выход; при ошибке код выхода 1.
    private static func renderSnapshots(to directory: URL) {
        do {
            let urls = try SnapshotRenderer.renderAll(to: directory)
            Self.log("снимков записано: \(urls.count) в \(directory.path(percentEncoded: false))")
            Log.flush()
            NSApp.terminate(nil)
        } catch {
            Self.log("снимки не получились: \(error)")
            Log.flush()
            exit(1)
        }
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
