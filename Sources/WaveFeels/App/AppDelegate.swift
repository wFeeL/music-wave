import AppKit
import CoreAudio

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var arguments = LaunchArguments()
    private(set) var model: AppModel?
    private(set) var windows: WindowsController?
    /// «Диагностика…» нажата до готовности модели: окно откроется сразу после запуска модели.
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
        Task { @MainActor in
            // Модель читает свойства Core Audio в главном потоке. Первое обращение к HAL
            // процесса может идти секундами, поэтому оно делается заранее вне главного потока.
            await Self.warmUpCoreAudio()
            let model = AppModel()
            let windows = WindowsController(model: model)
            self.model = model
            self.windows = windows
            model.start(arguments: arguments)
            if self.diagnosticsRequested {
                self.diagnosticsRequested = false
                windows.showDiagnostics()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        Log.flush()
    }

    func showDiagnostics() {
        if let windows {
            windows.showDiagnostics()
        } else {
            diagnosticsRequested = true
            Log.file("диагностика откроется после запуска модели")
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
