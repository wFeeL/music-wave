import AppKit
import Observation
import SwiftUI

/// Окно открыто и не свернуто в Dock. Живые части окна (таймеры, `TimelineView`) работают
/// только пока да.
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
    private let settingsPresence = WindowPresence()
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
            size: NSSize(width: 520, height: 660),
            autosaveName: "WaveFeelsSettings",
            content: SettingsView(model: model, presence: settingsPresence) { [weak self] in
                self?.showDiagnostics()
            }
        )
        settingsWindow = window
        if !settingsPresence.isOpen {
            settingsPresence.isOpen = true
        }
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

    func windowDidMiniaturize(_ notification: Notification) {
        setLive(false, for: notification)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        setLive(true, for: notification)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        setLive(false, for: notification)
        let othersOpen = [settingsWindow, diagnosticsWindow].contains { window in
            guard let window, window !== closing else { return false }
            return window.isVisible || window.isMiniaturized
        }
        if !othersOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func setLive(_ live: Bool, for notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let presence: WindowPresence
        if window === diagnosticsWindow {
            presence = diagnosticsPresence
        } else if window === settingsWindow {
            presence = settingsPresence
        } else {
            return
        }
        if presence.isOpen != live {
            presence.isOpen = live
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

    /// Показывает окно поверх остальных; свернутое в Dock разворачивается.
    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}
