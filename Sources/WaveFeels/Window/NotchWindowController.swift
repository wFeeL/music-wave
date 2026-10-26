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
/// `mouseMoved` видит каждое движение, в том числе над вырезом. Раскрытый остров и баннер
/// нового трека принимают события, а событий над окнами своего приложения монитор не видит,
/// поэтому только пока остров раскрыт или виден баннер, таймер 30 Гц опрашивает
/// `NSEvent.mouseLocation`. Смена состояния острова (`AppModel.onIslandStateChange`) сразу
/// пересчитывает клики и опрос: остров раскрывается по таймеру модели, когда курсор уже стоит
/// на месте. Панель лежит частью на строке меню, поэтому клики она принимает только над
/// раскрытым островом и над телом баннера (оно свисает на окно под строкой меню, и клик по
/// нему не должен уходить в это окно); свернутый остров без баннера их пропускает. Пока
/// виден баннер, зона наведения: баннер до верха экрана, и наведение на него раскрывает
/// полную панель. Если курсор уже стоял там, когда баннер появился, панель раскрывается,
/// только когда он сдвинется, войдет заново или по баннеру щелкнут.
/// Замер CPU (`--island`, `LaunchArguments.island`) подменяет только курсор в модели: при
/// `expanded` он всегда в зоне наведения (остров раскрывается машиной состояний, как при
/// наведении), при `collapsed` и `banner` всегда вне ее, щелчок по баннеру ничего не делает.
/// Клики и опрос курсора идут по состоянию острова, как обычно.
///
/// Свайп. Горизонтальная прокрутка двумя пальцами над островом листает треки
/// (`TrackSwipeDetector`, команда уходит в `AppModel.handleSwipe`). Мониторы `.scrollWheel`
/// стоят, только пока панель показана и свайп включен. Глобальный видит прокрутку, пока панель
/// пропускает события мыши (свернутый остров), локальный, пока принимает (раскрытый остров
/// или баннер), и поглощает прокрутку над островом. У выреза засчитываются оба: над вырезом
/// окон приложений нет. У капсулы только локальный (`NotchLayout.countsSwipe`), глобальный там
/// не ставится: пока капсула пропускает мышь, та же прокрутка листала бы и окно под ней.
/// Разрешений мониторы прокрутки не требуют (Универсальный доступ нужен только для клавиш).
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
    /// Где был курсор при последнем пересчете: опрос засчитывает движение, только если
    /// курсор сдвинулся.
    private var lastPointerLocation: NSPoint?
    /// Мониторы прокрутки для свайпа (`updateScrollMonitors`).
    private var scrollGlobalMonitor: Any?
    private var scrollLocalMonitor: Any?
    private var swipeDetector = TrackSwipeDetector()
    /// Первая прокрутка над островом с показа панели уже записана в лог: по монитору.
    private var loggedGlobalScroll = false
    private var loggedLocalScroll = false
    /// Номер подписки на ширину крыла, радиус свечения и свайп; `stop()` его меняет, и старая
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
                self?.updatePointer(moved: true)
            }
        }
        // Курсор над окнами настроек и диагностики глобальный монитор не видит.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.updatePointer(moved: true)
            }
            return event
        }
        model.onIslandStateChange = { [weak self] in
            // Зона свайпа сменилась: начатый жест (и его, возможно, потерянный `ended`) не в счет.
            self?.swipeDetector.cancelGesture()
            self?.updatePointer()
            // Глобальный монитор прокрутки стоит, только пока остров виден.
            self?.updateScrollMonitors()
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
            updateScrollMonitors()
            return
        }

        newLayout.wingWidth = CGFloat(model.settings.wingWidth)
        newLayout.glowRadius = model.settings.glowRadius
        // Период до нового острова: вид с новой рамкой сразу берет частоту кадров нового экрана.
        // Без смены рамки (у экрана сменилась частота) остров пересчитывается по наблюдению
        // за `AppModel.refreshPeriod`.
        let period = Self.refreshPeriod(screenID: newLayout.screenID)
        if model.refreshPeriod != period {
            model.refreshPeriod = period
            log("экран острова: \(Int((1 / period).rounded())) Гц")
        }
        if newLayout != layout {
            log(Self.describe(newLayout))
            place(newLayout)
        }
        if isShown {
            panel?.orderFrontRegardless()
            fullscreen.start(screenID: newLayout.screenID)
        }
        updatePointer()
        updateScrollMonitors()
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
        updateScrollMonitors()
        swipeDetector = TrackSwipeDetector()
        loggedGlobalScroll = false
        loggedLocalScroll = false
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

    /// Следит за шириной крыла, радиусом свечения и свайпом. `onChange` приходит до записи
    /// нового значения, поэтому панель переставляется (и мониторы прокрутки ставятся или
    /// снимаются) в следующем шаге главного актора; там же подписка продлевается, пока
    /// `generation` не устарел.
    private func observePanelSettings(generation: Int) {
        guard isShown, generation == settingsGeneration else { return }
        let settings = model.settings
        withObservationTracking {
            _ = settings.wingWidth
            _ = settings.glowRadius
            _ = settings.trackSwipe
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
        updateScrollMonitors()
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
        panel.onLeftMouseDown = { [weak self] in
            self?.panelClicked()
        }
        self.panel = panel
        self.hostingView = hostingView
    }

    // MARK: - Курсор

    /// Положение курсора в модель, пропуск кликов в панель, включение и выключение опроса.
    /// `moved`: вызов от движения мыши или опроса. Без движения (смена состояния острова или
    /// баннера, экранов, настроек) курсор, оказавшийся в зоне только потому, что под ним
    /// появился баннер, в зону не засчитывается. `polled`: вызов от опроса, движение
    /// засчитывается, только если курсор сдвинулся с прошлого пересчета.
    private func updatePointer(moved: Bool = false, polled: Bool = false) {
        guard isShown, let layout, let panel else {
            stopPolling()
            panel?.ignoresMouseEvents = true
            model.setPointerInHoverZone(false)
            return
        }
        let location = NSEvent.mouseLocation
        let movedNow = moved || (polled && location != lastPointerLocation)
        lastPointerLocation = location
        let banner = model.bannerVisible
        let pointer = layout.pointer(
            at: location,
            state: model.islandState,
            suppressed: model.islandSuppressed,
            banner: banner
        )
        let inside: Bool
        switch arguments.island {
        case .expanded?:
            inside = true
        case .collapsed?, .banner?:
            inside = false
        case nil:
            inside = NotchPointer.countsAsHover(
                inZone: pointer.inHoverZone, moved: movedNow, banner: banner, wasInZone: model.pointerInHoverZone
            )
        }
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
        model.setPointerInHoverZone(inside)
    }

    /// Нажатие в панели. По телу баннера (`NotchPointer.acceptsClicks`) раскрывает панель, как
    /// наведение, даже если курсор не двигался с появления баннера. С `--island` курсор задан
    /// замером, щелчок его не меняет.
    private func panelClicked() {
        guard isShown, arguments.island == nil, let layout, model.bannerVisible else { return }
        let pointer = layout.pointer(
            at: NSEvent.mouseLocation,
            state: model.islandState,
            suppressed: model.islandSuppressed,
            banner: true
        )
        guard pointer.acceptsClicks else { return }
        model.setPointerInHoverZone(true)
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePointer(polled: true)
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

    // MARK: - Свайп

    /// Ставит и снимает мониторы прокрутки. Они стоят, только пока панель показана, остров
    /// есть и свайп включен; глобальный только у выреза: у капсулы его события не считаются
    /// (`NotchLayout.countsSwipe`), и только пока остров не скрыт и не подавлен (пауза,
    /// блокировка экрана, полноэкранное окно): над скрытым островом свайпа нет. Выключенный свайп,
    /// капсула и скрытый остров не будят приложение на каждую прокрутку в других окнах. Смена
    /// состояния острова пересчитывает мониторы (`onIslandStateChange`); локальный монитор от
    /// состояния острова не зависит.
    ///
    /// Обработчики мониторов вызываются на главном потоке. Из события в главный актор уходят
    /// только значения (`SwipeScroll`), не само событие.
    private func updateScrollMonitors() {
        let before = (scrollGlobalMonitor != nil, scrollLocalMonitor != nil)
        let enabled = isShown && layout != nil && model.settings.trackSwipe
        let islandVisible = model.islandState != .hidden && !model.islandSuppressed
        let wantsGlobal = enabled && layout?.hasNotch == true && islandVisible

        if wantsGlobal, scrollGlobalMonitor == nil {
            scrollGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Чтение события повторено в обоих мониторах намеренно: общий помощник был бы
                // изолирован (главный актор или nonisolated), а изоляция `NSEvent` в SDK не известна.
                let scroll = SwipeScroll(
                    precise: event.hasPreciseScrollingDeltas,
                    phase: NotchWindowController.swipePhase(event.phase, momentum: event.momentumPhase),
                    fingerDX: Double(event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX),
                    dy: Double(event.scrollingDeltaY),
                    time: event.timestamp
                )
                MainActor.assumeIsolated {
                    _ = self?.handleScroll(scroll, global: true)
                }
            }
            if scrollGlobalMonitor == nil {
                log("глобальный монитор прокрутки не поставлен")
            }
        } else if !wantsGlobal, let monitor = scrollGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            scrollGlobalMonitor = nil
        }

        if enabled, scrollLocalMonitor == nil {
            scrollLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Повтор чтения события намеренный, причина у глобального монитора выше.
                let scroll = SwipeScroll(
                    precise: event.hasPreciseScrollingDeltas,
                    phase: NotchWindowController.swipePhase(event.phase, momentum: event.momentumPhase),
                    fingerDX: Double(event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX),
                    dy: Double(event.scrollingDeltaY),
                    time: event.timestamp
                )
                let consumed = MainActor.assumeIsolated {
                    self?.handleScroll(scroll, global: false) ?? false
                }
                return consumed ? nil : event
            }
        } else if !enabled, let monitor = scrollLocalMonitor {
            NSEvent.removeMonitor(monitor)
            scrollLocalMonitor = nil
        }

        let after = (scrollGlobalMonitor != nil, scrollLocalMonitor != nil)
        if after != before {
            log(Self.describeScrollMonitors(global: after.0, local: after.1))
        }
    }

    /// Прокрутка из глобального (`global`) или локального монитора. Засчитывается, если панель
    /// показана, свайп включен, раскладка ее принимает (`NotchLayout.countsSwipe`) и курсор над
    /// островом текущего состояния (`NotchLayout.swipeCovers`: без прозрачных плеч ниже полосы
    /// выреза). Смена состояния острова или баннера отменяет начатый жест
    /// (`onIslandStateChange`). В детектор идут только события
    /// трекпада (`hasPreciseScrollingDeltas`), колесо мыши нет. Возвращает, засчитана ли
    /// прокрутка над островом: локальный монитор такое событие поглощает.
    private func handleScroll(_ scroll: SwipeScroll, global: Bool) -> Bool {
        guard isShown, model.settings.trackSwipe, let layout, let panel else { return false }
        guard layout.countsSwipe(global: global, panelAcceptsMouse: !panel.ignoresMouseEvents) else { return false }
        guard layout.swipeCovers(
            NSEvent.mouseLocation,
            state: model.islandState, suppressed: model.islandSuppressed, banner: model.bannerVisible
        ) else { return false }
        logFirstScroll(global: global)
        guard scroll.precise else { return true }
        if let command = swipeDetector.feed(
            fingerDX: scroll.fingerDX, dy: scroll.dy, phase: scroll.phase, time: scroll.time
        ) {
            model.handleSwipe(command)
        }
        return true
    }

    /// Фаза прокрутки для `TrackSwipeDetector`. `NSEvent.Phase` это набор флагов, поэтому
    /// `contains`, а не сравнение. Непустая `momentumPhase`: инерция после жеста. Иначе
    /// `began` и `mayBegin` начинают жест, `changed` продолжает, `ended` и `cancelled`
    /// заканчивают. Пустая фаза (колесо мыши) и одна `stationary`: `.none`.
    nonisolated static func swipePhase(_ phase: NSEvent.Phase, momentum: NSEvent.Phase) -> TrackSwipeDetector.Phase {
        if !momentum.isEmpty { return .momentum }
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        return .none
    }

    /// Первая засчитанная прокрутка каждого монитора с показа панели: по логу видно, доходит
    /// ли прокрутка над островом, даже если свайп не сработал.
    private func logFirstScroll(global: Bool) {
        if global {
            guard !loggedGlobalScroll else { return }
            loggedGlobalScroll = true
            log("прокрутка над островом доходит: глобальный монитор")
        } else {
            guard !loggedLocalScroll else { return }
            loggedLocalScroll = true
            log("прокрутка над островом доходит: локальный монитор")
        }
    }

    private static func describeScrollMonitors(global: Bool, local: Bool) -> String {
        switch (global, local) {
        case (true, true):
            return "мониторы прокрутки для свайпа: глобальный и локальный"
        case (false, true):
            return "мониторы прокрутки для свайпа: только локальный"
        case (true, false):
            return "мониторы прокрутки для свайпа: только глобальный"
        case (false, false):
            return "мониторы прокрутки для свайпа сняты"
        }
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

/// Прокрутка для свайпа: значения из `NSEvent`, без самого события.
private struct SwipeScroll: Sendable {
    /// Трекпад или Magic Mouse (`hasPreciseScrollingDeltas`), не колесо мыши.
    var precise: Bool
    var phase: TrackSwipeDetector.Phase
    /// Сдвиг пальцев по горизонтали, вправо положительный, без учета «естественной прокрутки».
    var fingerDX: Double
    var dy: Double
    /// `NSEvent.timestamp`, секунды с загрузки системы.
    var time: Double
}

extension CGRect {
    /// «x 642.5, y 924.0, 185.0 × 32.0» для логов окна у выреза.
    var logDescription: String {
        String(format: "x %.1f, y %.1f, %.1f × %.1f", minX, minY, width, height)
    }
}
