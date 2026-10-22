import AppKit
import Observation
import SwiftUI

@main
struct WaveFeelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(delegate: appDelegate, holder: appDelegate.modelHolder)
        } label: {
            MenuBarIcon(holder: appDelegate.modelHolder)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Модель для меню строки меню: `AppDelegate` создает ее после запуска, до этого `nil`.
@MainActor
@Observable
final class AppModelHolder {
    var model: AppModel?

    /// Без изоляции: `AppDelegate` создает его в значении свойства по умолчанию.
    nonisolated init() {}

    /// Визуализация на паузе (до запуска модели нет).
    var paused: Bool {
        model?.settings.paused ?? false
    }
}

/// Иконка в строке меню: волна, на паузе перечеркнутая.
private struct MenuBarIcon: View {
    let holder: AppModelHolder

    var body: some View {
        Image(systemName: holder.paused ? "waveform.slash" : "waveform")
            .accessibilityLabel("WaveFeels")
    }
}

private struct MenuBarMenu: View {
    let delegate: AppDelegate
    let holder: AppModelHolder

    var body: some View {
        Button("Настройки…") {
            delegate.showSettings()
        }
        .keyboardShortcut(",")
        Button("Диагностика…") {
            delegate.showDiagnostics()
        }
        Button(holder.paused ? "Возобновить визуализацию" : "Приостановить визуализацию") {
            guard let model = holder.model else { return }
            model.setPaused(!model.settings.paused)
        }
        .disabled(holder.model == nil)
        Divider()
        Button("Выйти из WaveFeels") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
