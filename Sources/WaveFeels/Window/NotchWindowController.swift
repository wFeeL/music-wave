import AppKit
import CoreGraphics
import SwiftUI
import WaveCore

/// Панель у выреза: положение по экранам, курсор, пропуск кликов и полноэкранный режим.
///
/// Курсор. Глобальный монитор `mouseMoved` нужен только чтобы заметить вход в зону выреза:
/// событий над окнами своего приложения он не видит. Пока курсор в зоне или остров раскрыт,
/// таймер 30 Гц опрашивает `NSEvent.mouseLocation`; он выключается, когда остров не раскрыт
/// и курсор вне зоны. Панель лежит частью на строке меню, поэтому клики она принимает только
/// над раскрытым островом, свернутый остров всегда их пропускает.
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
    private var hostingView: NSHostingView<IslandPlaceholderView>?
    private var isShown = false
    private var screenObserver: (any NSObjectProtocol)?
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
                hostingView.rootView = IslandPlaceholderView(model: model, layout: newLayout)
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
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        stopPolling()
        fullscreen.stop()
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        model.pointerInHoverZone = false
    }

    // MARK: - Панель

    private func makePanel(layout: NotchLayout) {
        let frame = layout.panelFrame
        let panel = NotchPanel(contentRect: frame)
        let hostingView = NSHostingView(rootView: IslandPlaceholderView(model: model, layout: layout))
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
            if model.pointerInHoverZone {
                model.pointerInHoverZone = false
            }
            return
        }
        let pointer = layout.pointer(at: NSEvent.mouseLocation, state: model.islandState)
        if model.pointerInHoverZone != pointer.inHoverZone {
            model.pointerInHoverZone = pointer.inHoverZone
        }
        if panel.ignoresMouseEvents == pointer.acceptsClicks {
            panel.ignoresMouseEvents = !pointer.acceptsClicks
        }
        if pointer.needsPolling {
            startPolling()
        } else {
            stopPolling()
        }
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
        return "остров: экран \(layout.screenID), \(kind) \(describe(layout.notch)), панель \(describe(layout.panelFrame))"
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "x %.1f, y %.1f, %.1f × %.1f", rect.minX, rect.minY, rect.width, rect.height)
    }

    private func log(_ message: String) {
        Log.ui.info("\(message, privacy: .public)")
        Log.file(message)
    }
}

/// Временный остров до `IslandView`: черная капсула свернутого острова или прямоугольник
/// раскрытого, при скрытом острове панель прозрачна. Координаты из `NotchLayout` (AppKit,
/// снизу вверх) переводятся в координаты панели (SwiftUI, сверху вниз).
private struct IslandPlaceholderView: View {
    static let expandedCornerRadius: CGFloat = 24

    let model: AppModel
    let layout: NotchLayout

    var body: some View {
        let panel = layout.panelFrame
        ZStack(alignment: .topLeading) {
            Color.clear
            if let island = islandRect {
                let radius = model.islandState == .expanded ? Self.expandedCornerRadius : island.height / 2
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black)
                    .frame(width: island.width, height: island.height)
                    .offset(x: island.minX - panel.minX, y: panel.maxY - island.maxY)
            }
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.spring(duration: 0.35), value: model.islandState)
        .animation(.spring(duration: 0.35), value: model.settings.wingWidth)
    }

    private var islandRect: CGRect? {
        switch model.islandState {
        case .hidden: nil
        case .collapsed: layout.collapsedIsland(wingWidth: model.settings.wingWidth)
        case .expanded: layout.expandedIsland
        }
    }
}
