import AppKit
import SwiftUI

@main
struct WaveFeelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("WaveFeels", systemImage: "waveform") {
            Button("Диагностика…") {
                appDelegate.showDiagnostics()
            }
            Divider()
            Button("Выйти из WaveFeels") {
                NSApp.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
