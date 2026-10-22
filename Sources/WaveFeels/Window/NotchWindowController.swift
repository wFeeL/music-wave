import AppKit
import CoreGraphics
import Observation
import SwiftUI
import WaveCore

/// Панель у выреза: положение по экранам, курсор, пропуск кликов и полноэкранный режим.
///
/// Экраны. Вырез пересчитывается при смене параметров экранов и после пробуждения экранов,
/// заодно модель получает период кадра экрана острова (`AppModel.refreshPeriod`). Рамка панели
/// идет от текущих ширины крыла и «Радиуса свечения» (`NotchLayout.panelFrame`), а не от самых
/// больших: прозрачная площадь окна тоже стоит времени композитору. Смена любой из двух
/// настроек сразу переставляет панель.
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
    /// Номер подписки на ширину крыла и радиус свечения; `stop()` его меняет, и старая
    /// подписка больше не продлевается.
    private var settingsGeneration = 0

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
        observePanelSettings(generation: settingsGeneration)
    }

    /// Пересчитывает вырез по текущим экранам и переставляет панель.
    func relayout() {
        let screens = NSScreen.screens.map(Self.descriptor(for:))
        guard var newLayout = NotchGeometry.layout(for: screens, fakeNotch: arguments.fakeNotch) else {
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

        newLayout.wingWidth = CGFloat(model.settings.wingWidth)
        newLayout.glowRadius = model.settings.glowRadius
        if newLayout != layout {
            log(Self.describe(newLayout))
            place(newLayout)
        }
        let period = Self.refreshPeriod(screenID: newLayout.screenID)
        if model.refreshPeriod != period {
            model.refreshPeriod = period
            log("экран острова: \(Int((1 / period).rounded())) Гц")
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
        settingsGeneration += 1
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

    /// Запоминает `newLayout` и ставит по нему панель: рамку окна и остров в одном проходе.
    /// Сначала новый остров, потом рамка без немедленной отрисовки: окно и содержимое
    /// показываются вместе в следующем проходе, а не старый остров в новой рамке (сдвиг на
    /// кадр, когда крылья шире 150 pt меняют ширину окна).
    private func place(_ newLayout: NotchLayout) {
        layout = newLayout
        if let panel, let hostingView {
            hostingView.rootView = IslandView(model: model, layout: newLayout)
            panel.setFrame(newLayout.panelFrame, display: false)
        } else {
            makePanel(layout: newLayout)
        }
    }

    /// Следит за шириной крыла и радиусом свечения. `onChange` приходит до записи нового
    /// значения, поэтому панель переставляется в следующем шаге главного актора; там же
    /// подписка продлевается, пока `generation` не устарел.
    private func observePanelSettings(generation: Int) {
        guard isShown, generation == settingsGeneration else { return }
        let settings = model.settings
        withObservationTracking {
            _ = settings.wingWidth
            _ = settings.glowRadius
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.panelSettingsChanged(generation: generation)
            }
        }
    }

    private func panelSettingsChanged(generation: Int) {
        guard isShown, generation == settingsGeneration else { return }
        if var updated = layout {
            updated.wingWidth = CGFloat(model.settings.wingWidth)
            updated.glowRadius = model.settings.glowRadius
            if updated != layout {
                place(updated)
                updatePointer()
            }
        }
        observePanelSettings(generation: generation)
    }

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

    /// Описание экрана для `NotchGeometry`; им же вкладка «Вид» узнает предел крыла.
    static func descriptor(for screen: NSScreen) -> ScreenDescriptor {
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

    /// Период кадра экрана острова по его наибольшей частоте кадров; экран не найден: 1/60 с.
    private static func refreshPeriod(screenID: UInt32) -> Double {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[key] as? NSNumber)?.uint32Value == screenID
        }
        return RenderPacing.refreshPeriod(framesPerSecond: screen?.maximumFramesPerSecond ?? 0)
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
