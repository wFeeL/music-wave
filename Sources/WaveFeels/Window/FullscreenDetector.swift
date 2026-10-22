import AppKit
import CoreGraphics
import WaveCore

/// Занимает ли окно переднего приложения весь экран с вырезом.
///
/// Проверка идет при смене активного пространства и активного приложения: из
/// `CGWindowListCopyWindowInfo` берутся только рамки окон слоя 0 переднего приложения, без
/// названий и содержимого, поэтому записи экрана не нужно. Список окон читается вне главного
/// потока, устаревшие ответы отбрасываются по номеру проверки. Подписки снимает `stop()`.
@MainActor
final class FullscreenDetector {
    /// Через сколько повторить проверку: при смене пространства окна и переднее приложение
    /// обновляются не сразу, анимация перехода идет около 0,5 с.
    static let recheckDelay: Duration = .milliseconds(700)

    private(set) var isFullscreen = false
    var onChange: (() -> Void)?

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
            apply(false, details: "нет экрана или переднего приложения")
            return
        }
        Task { @MainActor [weak self] in
            let match = await Task.detached(priority: .utility) {
                FullscreenDetector.coveringWindow(query)
            }.value
            guard let self, current == self.generation else { return }
            self.apply(match != nil, details: match.map { "окно \(Self.describe($0)), \(query.appName)" } ?? query.appName)
        }
    }

    private func apply(_ fullscreen: Bool, details: String) {
        guard fullscreen != isFullscreen else { return }
        isFullscreen = fullscreen
        let message = "полноэкранное окно: \(fullscreen ? "да" : "нет") (\(details))"
        Log.ui.info("\(message, privacy: .public)")
        Log.file(message)
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

    /// Рамка (координаты AppKit) первого окна слоя 0 приложения `query.pid`, которое занимает
    /// экран целиком, или `nil`.
    private nonisolated static func coveringWindow(_ query: Query) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == query.pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let windowServerRect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            let rect = NotchGeometry.appKitRect(
                fromWindowServer: windowServerRect,
                primaryScreenHeight: query.primaryScreenHeight
            )
            if NotchGeometry.windowCoversScreen(rect, screen: query.screenFrame, topAllowance: query.topAllowance) {
                return rect
            }
        }
        return nil
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "x %.0f, y %.0f, %.0f × %.0f", rect.minX, rect.minY, rect.width, rect.height)
    }
}
