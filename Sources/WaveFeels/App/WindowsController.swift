import AppKit
import Observation
import SwiftUI

/// Открыто ли окно сейчас. Живые части окна (таймеры, `TimelineView`) работают только пока да.
@MainActor
@Observable
final class WindowPresence {
    var isOpen = false
}

/// Окна настроек и диагностики на AppKit: `NSWindow` с `NSHostingController`, без сцены
/// `Settings`. Пока открыто хотя бы одно окно, приложение видно в Dock (`.regular`), чтобы окно
/// не пряталось за другими; после закрытия последнего снова `.accessory`. Окна создаются один раз
/// и переиспользуются.
@MainActor
final class WindowsController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let diagnosticsPresence = WindowPresence()
    private var settingsWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func showSettings() {
        let window = settingsWindow ?? makeWindow(
            title: "Настройки WaveFeels",
            size: NSSize(width: 460, height: 280),
            autosaveName: "WaveFeelsSettings",
            content: SettingsPlaceholderView()
        )
        settingsWindow = window
        present(window)
    }

    func showDiagnostics() {
        let window = diagnosticsWindow ?? makeWindow(
            title: "Диагностика WaveFeels",
            size: NSSize(width: 680, height: 760),
            autosaveName: "WaveFeelsDiagnostics",
            content: DiagnosticsView(model: model, presence: diagnosticsPresence)
        )
        diagnosticsWindow = window
        if !diagnosticsPresence.isOpen {
            diagnosticsPresence.isOpen = true
        }
        present(window)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === diagnosticsWindow, diagnosticsPresence.isOpen {
            diagnosticsPresence.isOpen = false
        }
        let othersOpen = [settingsWindow, diagnosticsWindow].contains { window in
            guard let window, window !== closing else { return false }
            return window.isVisible || window.isMiniaturized
        }
        if !othersOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Окна

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        autosaveName: String,
        content: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: content)
        // Только минимальный размер от SwiftUI: окно не прыгает при обновлении содержимого.
        controller.sizingOptions = [.minSize]
        window.contentViewController = controller
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName(autosaveName)
        window.delegate = self
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Заглушка до окна настроек.
private struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Настройки появятся в следующей сборке")
                .font(.headline)
            Text("Состояние захвата и Now Playing видно в окне «Диагностика».")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(minWidth: 400, minHeight: 220)
    }
}
