import AppKit
import CoreGraphics
import SwiftUI
import WaveCore

/// Панель у выреза: положение по экранам, курсор, пропуск кликов и полноэкранный режим.
///
/// Экраны. Вырез пересчитывается при смене параметров экранов и после пробуждения экранов.
/// Остров стоит только на встроенном экране с вырезом; если его нет (внешний монитор при
/// закрытой крышке), капсула встает под строку меню основного экрана (`NotchGeometry.layout`).
///
/// Курсор. Пока остров не раскрыт, панель пропускает события мыши, и глобальный монитор
/// `mouseMoved` видит каждое движение, в том числе над вырезом. Раскрытый остров принимает
/// события, а событий над окнами своего приложения монитор не видит, поэтому только пока
/// остров раскрыт, таймер 30 Гц опрашивает `NSEvent.mouseLocation`. Смена состояния острова
/// (`AppModel.onIslandStateChange`) сразу пересчитывает клики и опрос: остров раскрывается
/// по таймеру модели, когда курсор уже стоит на месте. Панель лежит частью на строке меню,
/// поэтому клики она принимает только над раскрытым островом, свернутый остров всегда их
/// пропускает.
///
/// Подписок и таймеров в `deinit` нет: владелец вызывает `stop()`.
@MainActor
final class NotchWindowController {
    static let pollInterval: TimeInterval = 1.0 / 30

    private(set) var layout: NotchLayout?

    private let model: AppModel
    private let arguments: LaunchArguments
    private let fullscreen = FullscreenDetector()
    private var panel: NotchPanel?
    private var hostingView: NSHostingView<IslandView>?
    private var isShown = false
    private var screenObserver: (any NSObjectProtocol)?
    /// Экраны проснулись: панель ставится заново и выводится вперед.
    private var screensWakeObserver: (any NSObjectProtocol)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?

    init(model: AppModel, arguments: LaunchArguments) {
        self.model = model
        self.arguments = arguments
        fullscreen.onChange = { [weak self] in
            self?.fullscreenChanged()
        }
    }

    /// Ставит панель у выреза и начинает следить за экранами, курсором и полноэкранными окнами.
    func show() {
        guard !isShown else { return }
        isShown = true

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relayout()
            }
        }
        screensWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relayout()
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePointer()
            }
        }
        // Курсор над окнами настроек и диагностики глобальный монитор не видит.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.updatePointer()
            }
            return event
        }
        model.onIslandStateChange = { [weak self] in
            self?.updatePointer()
        }
        relayout()
    }

    /// Пересчитывает вырез по текущим экранам и переставляет панель.
    func relayout() {
        let screens = NSScreen.screens.map(Self.descriptor(for:))
        guard let newLayout = NotchGeometry.layout(for: screens, fakeNotch: arguments.fakeNotch) else {
            if layout != nil {
                log("экранов нет, панель у выреза убрана")
            }
            layout = nil
            panel?.orderOut(nil)
            fullscreen.stop()
            fullscreenChanged()
            updatePointer()
            return
        }

        if newLayout != layout {
            layout = newLayout
            log(Self.describe(newLayout))
            if let panel, let hostingView {
                panel.setFrame(newLayout.panelFrame, display: true)
                hostingView.rootView = IslandView(model: model, layout: newLayout)
            } else {
                makePanel(layout: newLayout)
            }
        }
        if isShown {
            panel?.orderFrontRegardless()
            fullscreen.start(screenID: newLayout.screenID)
        }
        updatePointer()
    }

    /// Снимает подписки, мониторы и таймер, убирает панель.
    func stop() {
        isShown = false
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        if let screensWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensWakeObserver)
        }
        screensWakeObserver = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        model.onIslandStateChange = nil
        stopPolling()
        fullscreen.stop()
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        model.setPointerInHoverZone(false)
    }

    // MARK: - Панель

    private func makePanel(layout: NotchLayout) {
        let frame = layout.panelFrame
        let panel = NotchPanel(contentRect: frame)
        let hostingView = NSHostingView(rootView: IslandView(model: model, layout: layout))
        // Размер окна задает только геометрия выреза, не содержимое SwiftUI.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setFrame(frame, display: false)
        self.panel = panel
        self.hostingView = hostingView
    }

    // MARK: - Курсор

    /// Положение курсора в модель, пропуск кликов в панель, включение и выключение опроса.
    private func updatePointer() {
        guard isShown, let layout, let panel else {
            stopPolling()
            panel?.ignoresMouseEvents = true
            model.setPointerInHoverZone(false)
            return
        }
        let pointer = layout.pointer(
            at: NSEvent.mouseLocation,
            state: model.islandState,
            suppressed: model.islandSuppressed
        )
        if panel.ignoresMouseEvents == pointer.acceptsClicks {
            panel.ignoresMouseEvents = !pointer.acceptsClicks
        }
        if pointer.needsPolling {
            startPolling()
        } else {
            stopPolling()
        }
        // Последним: если остров от этого сменит состояние, вложенный вызов через
        // `onIslandStateChange` пересчитает клики и опрос уже для нового состояния.
        model.setPointerInHoverZone(pointer.inHoverZone)
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePointer()
            }
        }
        timer.tolerance = Self.pollInterval / 4
        // `.common`: опрос идет и пока открыто меню в строке меню.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Полноэкранный режим

    private func fullscreenChanged() {
        let suppressed = fullscreen.isFullscreen
        if model.fullscreenSuppressed != suppressed {
            model.fullscreenSuppressed = suppressed
        }
    }

    // MARK: - Экраны

    private static func descriptor(for screen: NSScreen) -> ScreenDescriptor {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let id: CGDirectDisplayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
        return ScreenDescriptor(
            id: id,
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            isBuiltIn: id != 0 && CGDisplayIsBuiltin(id) != 0,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY
        )
    }

    private static func describe(_ layout: NotchLayout) -> String {
        let kind = layout.hasNotch ? "вырез" : "капсула под строкой меню"
        return "остров: экран \(layout.screenID), \(kind) \(layout.notch.logDescription), "
            + "панель \(layout.panelFrame.logDescription)"
    }

    private func log(_ message: String) {
        Log.ui.info("\(message, privacy: .public)")
        Log.file(message)
    }
}

extension CGRect {
    /// «x 642.5, y 924.0, 185.0 × 32.0» для логов окна у выреза.
    var logDescription: String {
        String(format: "x %.1f, y %.1f, %.1f × %.1f", minX, minY, width, height)
    }
}
