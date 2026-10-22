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

    /// Нет доступа к звуку (`AppModel.permissionHint`).
    var permissionHint: Bool {
        model?.permissionHint ?? false
    }

    /// Значок в строке меню: волна, на паузе перечеркнутая, без доступа к звуку с восклицательным
    /// знаком. Доступ важнее паузы: без него визуализация не заработает и после паузы.
    nonisolated static func iconName(paused: Bool, permissionHint: Bool) -> String {
        if permissionHint { return "waveform.badge.exclamationmark" }
        return paused ? "waveform.slash" : "waveform"
    }
}

/// Иконка в строке меню, см. `AppModelHolder.iconName`.
private struct MenuBarIcon: View {
    let holder: AppModelHolder

    var body: some View {
        Image(systemName: AppModelHolder.iconName(paused: holder.paused, permissionHint: holder.permissionHint))
            .accessibilityLabel(holder.permissionHint ? "WaveFeels, нет доступа к звуку" : "WaveFeels")
    }
}

private struct MenuBarMenu: View {
    let delegate: AppDelegate
    let holder: AppModelHolder

    var body: some View {
        if holder.permissionHint {
            // Без окон подсказку иначе не увидеть: пункт ведет в диагностику с кнопками доступа.
            Button("Нет доступа к звуку…") {
                delegate.showDiagnostics()
            }
            Divider()
        }
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
