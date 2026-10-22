import Foundation
import ServiceManagement

/// «Запускать при входе в систему» через `SMAppService.mainApp`.
///
/// Запись входа ссылается на путь приложения, поэтому переключатель работает только из
/// `/Applications`: копия из «Загрузок» или распакованного архива пропала бы при уборке.
@MainActor
enum LaunchAtLogin {
    static let moveHint = "Сначала перенесите WaveFeels в папку Программы"
    static let approvalHint = "Разрешите WaveFeels в Системных настройках, раздел «Объекты входа»"

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Переключатель включен: запись есть, даже если ее еще надо разрешить.
    static var isEnabled: Bool {
        isOn(status)
    }

    static func isOn(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Приложение лежит в `/Applications`.
    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.hasPrefix("/Applications/")
    }

    /// Включает или выключает запуск при входе. Возвращает текст для пользователя или `nil`,
    /// если все получилось. После вызова статус всегда перечитывается: `register()` может
    /// бросить ошибку и все равно создать запись, ждущую разрешения. Тогда открываются
    /// «Объекты входа» в Системных настройках.
    static func set(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        var failure: (any Error)?
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            failure = error
        }
        let status = service.status
        log("запуск при входе: \(enabled ? "включение" : "выключение"), статус \(describe(status))"
            + (failure.map { ", ошибка: \($0.localizedDescription)" } ?? ""))

        if enabled {
            switch status {
            case .enabled:
                return nil
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
                return approvalHint
            default:
                return "Не удалось включить запуск при входе"
                    + (failure.map { ": \($0.localizedDescription)" } ?? "")
            }
        }
        if status == .enabled || status == .requiresApproval {
            return "Не удалось выключить запуск при входе"
                + (failure.map { ": \($0.localizedDescription)" } ?? "")
        }
        return nil
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "не включен"
        case .enabled: "включен"
        case .requiresApproval: "ждет разрешения"
        case .notFound: "не найден"
        @unknown default: "неизвестно (\(status.rawValue))"
        }
    }

    private static func log(_ message: String) {
        Log.app.info("\(message, privacy: .public)")
        Log.file(message)
    }
}
