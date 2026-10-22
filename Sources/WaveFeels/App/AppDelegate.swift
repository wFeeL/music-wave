import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var arguments = LaunchArguments()

    func applicationDidFinishLaunching(_ notification: Notification) {
        arguments = LaunchArguments.parse(ProcessInfo.processInfo.arguments)

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let line = "WaveFeels \(version) (\(build)), macOS \(system), подпись: \(SigningInfo.current())"
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.flush()
    }
}
