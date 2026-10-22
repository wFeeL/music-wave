import AppKit
import Observation
import SwiftUI

/// Окно открыто и не свернуто в Dock (`isOpen`) и хоть чем-то видно на экране (`isVisible`,
/// по `NSWindow.occlusionState`: не закрыто целиком другими окнами, не на другом рабочем столе,
/// приложение не скрыто). Живые части окна (таймеры, `TimelineView`) работают только пока да.
@MainActor
@Observable
final class WindowPresence {
    var isOpen = false
    var isVisible = false
}

/// Окна настроек и диагностики на AppKit: `NSWindow` с `NSHostingController`, без сцены
/// `Settings`. Пока открыто хотя бы одно окно, приложение видно в Dock (`.regular`), чтобы окно
/// не пряталось за другими; после закрытия последнего снова `.accessory`. Окна создаются один раз
/// и переиспользуются. При каждом показе рамка окна ужимается до видимой области его экрана:
/// окно настроек 880 pt в высоту и сохраненная рамка с большого монитора не уходят за край
/// маленького.
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
            size: SettingsView.windowSize,
            minSize: SettingsView.minSize,
            // Новое имя: рамка заглушки прежних версий (460 × 280) не восстанавливается.
            autosaveName: "WaveFeelsSettingsV2",
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
            minSize: NSSize(width: 560, height: 480),
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

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        setVisible(window.occlusionState.contains(.visible), for: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        setLive(false, for: notification)
        setVisible(false, for: closing)
        let othersOpen = [settingsWindow, diagnosticsWindow].contains { window in
            guard let window, window !== closing else { return false }
            return window.isVisible || window.isMiniaturized
        }
        if !othersOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func setLive(_ live: Bool, for notification: Notification) {
        guard let window = notification.object as? NSWindow, let presence = presence(of: window) else { return }
        if presence.isOpen != live {
            presence.isOpen = live
        }
    }

    private func setVisible(_ visible: Bool, for window: NSWindow) {
        guard let presence = presence(of: window) else { return }
        if presence.isVisible != visible {
            presence.isVisible = visible
        }
    }

    private func presence(of window: NSWindow) -> WindowPresence? {
        if window === diagnosticsWindow { return diagnosticsPresence }
        if window === settingsWindow { return settingsPresence }
        return nil
    }

    // MARK: - Окна

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        minSize: NSSize,
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
        // Сохраненная рамка могла остаться меньше минимума содержимого: окно растет вправо
        // и вниз, левый верхний угол остается на месте.
        let frame = window.frame
        let restored = window.contentRect(forFrameRect: frame).size
        if restored.width < minSize.width || restored.height < minSize.height {
            let content = NSRect(
                x: 0, y: 0,
                width: max(restored.width, minSize.width),
                height: max(restored.height, minSize.height)
            )
            let grown = window.frameRect(forContentRect: content)
            window.setFrame(
                NSRect(x: frame.minX, y: frame.maxY - grown.height, width: grown.width, height: grown.height),
                display: false
            )
        }
        window.delegate = self
        return window
    }

    /// Показывает окно поверх остальных; свернутое в Dock разворачивается. Рамка ужимается до
    /// видимой области экрана окна (без строки меню и Dock).
    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let fitted = Self.fitted(window.frame, in: visible)
            if fitted != window.frame {
                window.setFrame(fitted, display: false)
            }
        }
        window.makeKeyAndOrderFront(nil)
        // Уведомление о видимости придет после вывода окна; до него берется текущее состояние.
        setVisible(window.occlusionState.contains(.visible), for: window)
    }

    /// Рамка `frame`, ужатая до `visible` и сдвинутая внутрь нее: верхний край по возможности
    /// остается на месте. Пустая `visible` ничего не меняет.
    static func fitted(_ frame: NSRect, in visible: NSRect) -> NSRect {
        guard visible.width > 0, visible.height > 0 else { return frame }
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let top = min(max(frame.maxY, visible.minY + height), visible.maxY)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}
