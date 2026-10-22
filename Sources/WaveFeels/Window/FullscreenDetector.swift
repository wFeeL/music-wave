import AppKit
import CoreGraphics
import WaveCore

/// Занимает ли окно переднего приложения весь экран с вырезом, и спрятана ли на нем строка меню.
///
/// Проверка идет при смене активного пространства и активного приложения: из
/// `CGWindowListCopyWindowInfo` берутся только владелец, слой и рамка окон, без названий
/// и содержимого, поэтому записи экрана не нужно. Решение принимает
/// `NotchGeometry.fullscreenCheck`: окно слоя 0 во весь экран и нет видимой строки меню. Список окон читается вне главного
/// потока, устаревшие ответы отбрасываются по номеру проверки. Подписки снимает `stop()`.
@MainActor
final class FullscreenDetector {
    /// Через сколько повторить проверку: при смене пространства окна и переднее приложение
    /// обновляются не сразу, анимация перехода идет около 0,5 с.
    static let recheckDelay: Duration = .milliseconds(700)

    private(set) var isFullscreen = false
    var onChange: (() -> Void)?

    /// Последний результат проверки; в лог пишется только смена признаков.
    private var lastCheck: FullscreenCheck?

    private var screenID: CGDirectDisplayID?
    private var observers: [any NSObjectProtocol] = []
    private var recheckTask: Task<Void, Never>?
    /// Номер последней запущенной проверки; ответы старых проверок не применяются.
    private var generation = 0

    /// Начинает следить за экраном `screenID`; повторный вызов меняет экран и проверяет сразу.
    func start(screenID: CGDirectDisplayID) {
        self.screenID = screenID
        if observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
                let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.environmentChanged()
                    }
                }
                observers.append(observer)
            }
        }
        check()
    }

    /// Снимает подписки и сбрасывает состояние без вызова `onChange`.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
        recheckTask?.cancel()
        recheckTask = nil
        generation += 1
        screenID = nil
        isFullscreen = false
        lastCheck = nil
    }

    private func environmentChanged() {
        check()
        recheckTask?.cancel()
        recheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.recheckDelay)
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    private func check() {
        generation += 1
        let current = generation
        guard let query = makeQuery() else {
            apply(FullscreenCheck(coveringWindow: nil, menuBarVisible: false), appName: "нет экрана или переднего приложения")
            return
        }
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                FullscreenDetector.evaluate(query)
            }.value
            guard let self, current == self.generation else { return }
            self.apply(result, appName: query.appName)
        }
    }

    private func apply(_ result: FullscreenCheck, appName: String) {
        let previous = lastCheck
        lastCheck = result
        let signalsChanged = previous?.coveringWindow != result.coveringWindow
            || previous?.menuBarVisible != result.menuBarVisible
        let fullscreen = result.isFullscreen
        if signalsChanged, previous != nil || result.coveringWindow != nil {
            let window = result.coveringWindow.map { "во весь экран, \($0.logDescription)" } ?? "не во весь экран"
            let message = "полноэкранный режим: \(fullscreen ? "да" : "нет") (окно \(window), "
                + "строка меню \(result.menuBarVisible ? "видна" : "не видна"), \(appName))"
            Log.ui.info("\(message, privacy: .public)")
            Log.file(message)
        }
        guard fullscreen != isFullscreen else { return }
        isFullscreen = fullscreen
        onChange?()
    }

    // MARK: - Окна

    /// Все, что нужно для проверки вне главного потока.
    private struct Query: Sendable {
        var pid: pid_t
        var appName: String
        /// Экран с вырезом, координаты AppKit.
        var screenFrame: CGRect
        /// Высота выреза: полноэкранное окно может стоять под ним.
        var topAllowance: CGFloat
        /// Высота основного экрана для перевода координат CGWindow.
        var primaryScreenHeight: CGFloat
    }

    private func makeQuery() -> Query? {
        guard let screenID,
              let app = NSWorkspace.shared.frontmostApplication,
              let primary = NSScreen.screens.first else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == screenID
        }) else { return nil }
        return Query(
            pid: app.processIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            screenFrame: screen.frame,
            topAllowance: screen.safeAreaInsets.top,
            primaryScreenHeight: primary.frame.height
        )
    }

    /// Читает список окон на экране и передает его в `NotchGeometry.fullscreenCheck`.
    private nonisolated static func evaluate(_ query: Query) -> FullscreenCheck {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap { info -> ServerWindow? in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return ServerWindow(pid: pid, layer: layer, bounds: rect)
        }
        return NotchGeometry.fullscreenCheck(
            windows: windows,
            pid: query.pid,
            screen: query.screenFrame,
            topAllowance: query.topAllowance,
            menuBarLayer: Int(CGWindowLevelForKey(.mainMenuWindow)),
            primaryScreenHeight: query.primaryScreenHeight
        )
    }
}
