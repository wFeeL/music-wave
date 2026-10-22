import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Описание экрана для расчета геометрии. Координаты AppKit: начало снизу слева, ось Y вверх.
public struct ScreenDescriptor: Sendable, Equatable {
    public var id: UInt32
    public var frame: CGRect
    /// Высота выреза сверху (`safeAreaInsets.top`), 0 на экране без выреза.
    public var safeAreaTop: CGFloat
    public var auxiliaryLeftWidth: CGFloat?
    public var auxiliaryRightWidth: CGFloat?
    public var isBuiltIn: Bool
    public var menuBarHeight: CGFloat

    public init(
        id: UInt32, frame: CGRect, safeAreaTop: CGFloat,
        auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?,
        isBuiltIn: Bool, menuBarHeight: CGFloat
    ) {
        self.id = id
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryLeftWidth = auxiliaryLeftWidth
        self.auxiliaryRightWidth = auxiliaryRightWidth
        self.isBuiltIn = isBuiltIn
        self.menuBarHeight = menuBarHeight
    }
}

/// Положение выреза (или капсулы-замены) на выбранном экране и производные прямоугольники острова.
public struct NotchLayout: Sendable, Equatable {
    public var screenID: UInt32
    /// Рамка выбранного экрана, нужна для ограничения панели и зоны наведения.
    public var screenFrame: CGRect
    public var hasNotch: Bool
    public var notch: CGRect

    public init(screenID: UInt32, screenFrame: CGRect, hasNotch: Bool, notch: CGRect) {
        self.screenID = screenID
        self.screenFrame = screenFrame
        self.hasNotch = hasNotch
        self.notch = notch
    }

    /// Свернутый остров: вырез плюс крылья по бокам. Верх и высота как у выреза. У капсулы
    /// крыльев нет: свернутая капсула ровно `NotchGeometry.pillSize`.
    public func collapsedIsland(wingWidth: CGFloat) -> CGRect {
        let wing = hasNotch ? min(max(wingWidth, 0), NotchGeometry.maxWingWidth) : 0
        return CGRect(
            x: notch.minX - wing, y: notch.minY,
            width: notch.width + 2 * wing, height: notch.height
        )
    }

    /// Размер раскрытого острова. У выреза: `NotchGeometry.expandedSize` (под вырез 32 pt),
    /// а под более высокий вырез панель выше на разницу, чтобы под вырезом осталось столько же
    /// места. У капсулы: `NotchGeometry.pillExpandedSize`, без зоны под вырез.
    public var expandedSize: CGSize {
        guard hasNotch else { return NotchGeometry.pillExpandedSize }
        let extra = max(notch.height - NotchGeometry.baseNotchHeight, 0)
        return CGSize(width: NotchGeometry.expandedSize.width, height: NotchGeometry.expandedSize.height + extra)
    }

    /// От верха раскрытого острова до верха его содержимого (обложки). У выреза: высота выреза
    /// (не меньше 32 pt) плюс `notchClearance`, под камерой ничего нет. У капсулы: `pillContentInset`.
    public var expandedContentTop: CGFloat {
        guard hasNotch else { return NotchGeometry.pillContentInset }
        return max(notch.height, NotchGeometry.baseNotchHeight) + NotchGeometry.notchClearance
    }

    /// Раскрытый остров: `expandedSize` по центру выреза, верх на уровне верха выреза.
    public var expandedIsland: CGRect {
        let size = expandedSize
        return CGRect(
            x: notch.midX - size.width / 2, y: notch.maxY - size.height,
            width: size.width, height: size.height
        )
    }

    /// Где раскрытый остров принимает клики: только видимое тело. У выреза рамка шире тела на
    /// плечи `expandedShoulderRadius` с каждой стороны; полосы под ними прозрачны и частью лежат
    /// на строке меню, поэтому клики там уходят мимо. У капсулы плеч нет.
    public var expandedClickArea: CGRect {
        hasNotch ? expandedIsland.insetBy(dx: NotchGeometry.expandedShoulderRadius, dy: 0) : expandedIsland
    }

    /// Рамка панели: раскрытый и самый широкий свернутый остров плюс запас снизу под свечение
    /// и по бокам под тень и «вздох», по горизонтали не выходит за экран.
    public var panelFrame: CGRect {
        let union = expandedIsland.union(collapsedIsland(wingWidth: NotchGeometry.maxWingWidth))
        let minX = max(union.minX - NotchGeometry.panelSideMargin, screenFrame.minX)
        let maxX = min(union.maxX + NotchGeometry.panelSideMargin, screenFrame.maxX)
        return CGRect(
            x: minX, y: union.minY - NotchGeometry.glowMargin,
            width: max(maxX - minX, 0), height: union.height + NotchGeometry.glowMargin
        )
    }

    /// Зона наведения. Свернутая: вырез, продленный до верха экрана, без крыльев. Раскрытая:
    /// раскрытый остров (в режиме капсулы продленный до верха экрана). Обе зоны выступают
    /// выше экрана на `hoverTopOvershoot`, иначе курсор на самой верхней строке пикселей
    /// (`y == frame.maxY`) не попадал бы в полуоткрытый `CGRect`.
    public func hoverZone(expanded: Bool) -> CGRect {
        let base = expanded ? expandedIsland : notch
        let top = max(screenFrame.maxY, base.maxY) + NotchGeometry.hoverTopOvershoot
        return CGRect(x: base.minX, y: base.minY, width: base.width, height: top - base.minY)
    }

    /// Что делать с курсором в точке `point` (глобальные координаты AppKit) при состоянии `state`.
    /// `suppressed`: остров принудительно скрыт (пауза, блокировка экрана, полноэкранное окно)
    /// и на курсор не отвечает, поэтому ни опроса, ни кликов.
    public func pointer(at point: CGPoint, state: IslandState, suppressed: Bool = false) -> NotchPointer {
        let expanded = state == .expanded && !suppressed
        let inHoverZone = hoverZone(expanded: expanded).contains(point)
        return NotchPointer(
            inHoverZone: inHoverZone,
            acceptsClicks: expanded && expandedClickArea.contains(point),
            needsPolling: !suppressed && (expanded || inHoverZone)
        )
    }
}

/// Решение по положению курсора у выреза.
public struct NotchPointer: Sendable, Equatable {
    /// Курсор в зоне наведения, идет в `IslandInputs.pointerInHoverZone`.
    public var inHoverZone: Bool
    /// Окно принимает клики. Только раскрытый остров и только над его видимым телом
    /// (`expandedClickArea`): свернутый остров, полосы под плечами и все вокруг пропускают
    /// клики в строку меню.
    public var acceptsClicks: Bool
    /// Нужен частый опрос курсора: глобальный монитор не видит событий над своими окнами.
    public var needsPolling: Bool

    public init(inHoverZone: Bool, acceptsClicks: Bool, needsPolling: Bool) {
        self.inHoverZone = inHoverZone
        self.acceptsClicks = acceptsClicks
        self.needsPolling = needsPolling
    }
}

public enum NotchGeometry {
    /// Видимая ширина раскрытой панели у выреза и у капсулы.
    public static let expandedBodyWidth: CGFloat = 468
    /// Вогнутые плечи раскрытой панели у выреза: рамка шире тела на них с каждой стороны.
    public static let expandedShoulderRadius: CGFloat = 9
    /// Раскрытый остров у выреза высотой `baseNotchHeight`.
    public static let expandedSize = CGSize(width: expandedBodyWidth + 2 * expandedShoulderRadius, height: 170)
    /// Высота выреза, под которую рассчитан `expandedSize`.
    public static let baseNotchHeight: CGFloat = 32
    /// Зазор между низом выреза и содержимым панели.
    public static let notchClearance: CGFloat = 13
    /// Раскрытая капсула на экране без выреза: зоны под вырез нет.
    public static let pillExpandedSize = CGSize(width: expandedBodyWidth, height: 150)
    /// Отступ содержимого раскрытой капсулы со всех сторон.
    public static let pillContentInset: CGFloat = 16
    public static let pillSize = CGSize(width: 240, height: 28)
    public static let maxWingWidth: CGFloat = 120
    /// Насколько зона наведения выступает выше верха экрана.
    static let hoverTopOvershoot: CGFloat = 2
    /// Запас под панелью для свечения.
    static let glowMargin: CGFloat = 40
    /// Запас панели по бокам: тень раскрытого острова и «вздох» не обрезаются краем окна.
    public static let panelSideMargin: CGFloat = 24
    /// Отступ капсулы от строки меню на экране без выреза.
    static let pillGap: CGFloat = 8
    static let fakeNotchSize = CGSize(width: 185, height: 32)

    public static func layout(for screens: [ScreenDescriptor], fakeNotch: Bool = false) -> NotchLayout? {
        guard let first = screens.first else { return nil }

        if fakeNotch {
            return NotchLayout(
                screenID: first.id, screenFrame: first.frame, hasNotch: true,
                notch: centeredNotch(size: fakeNotchSize, top: first.frame.maxY, in: first.frame)
            )
        }

        if let screen = screens.first(where: { $0.isBuiltIn && $0.safeAreaTop > 0 }),
           let left = screen.auxiliaryLeftWidth, let right = screen.auxiliaryRightWidth,
           left + right < screen.frame.width {
            let notch = CGRect(
                x: screen.frame.minX + left, y: screen.frame.maxY - screen.safeAreaTop,
                width: screen.frame.width - left - right, height: screen.safeAreaTop
            )
            return NotchLayout(screenID: screen.id, screenFrame: screen.frame, hasNotch: true, notch: notch)
        }

        return NotchLayout(
            screenID: first.id, screenFrame: first.frame, hasNotch: false,
            notch: centeredNotch(size: pillSize, top: first.frame.maxY - first.menuBarHeight - pillGap, in: first.frame)
        )
    }

    /// Рамка окна из `kCGWindowBounds` (начало сверху слева основного экрана, ось Y вниз)
    /// в координатах AppKit (начало снизу слева основного экрана, ось Y вверх).
    public static func appKitRect(fromWindowServer rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Окно (координаты AppKit) занимает весь экран: по ширине и до низа целиком, сверху
    /// допускается полоса до `topAllowance` (полноэкранное окно может стоять под вырезом).
    public static func windowCoversScreen(_ window: CGRect, screen: CGRect, topAllowance: CGFloat) -> Bool {
        let tolerance = fullscreenTolerance
        return window.minX <= screen.minX + tolerance
            && window.maxX >= screen.maxX - tolerance
            && window.minY <= screen.minY + tolerance
            && window.maxY >= screen.maxY - max(topAllowance, 0) - tolerance
    }

    /// Допуск сравнения рамок полноэкранного окна и экрана, pt.
    static let fullscreenTolerance: CGFloat = 1
    /// Высота полосы у верха экрана, которую должна задевать видимая строка меню, pt.
    static let menuBarProbeHeight: CGFloat = 1

    /// Полноэкранный режим на экране `screen` (координаты AppKit): окно слоя 0 приложения `pid`
    /// занимает экран (`windowCoversScreen`), и строки меню у верха этого экрана нет. По одной
    /// рамке растянутое окно под строкой меню при скрытом Dock не отличить от полноэкранного,
    /// а в полноэкранном пространстве строка меню спрятана. Строка меню ищется как окно слоя
    /// `menuBarLayer` (`CGWindowLevelForKey(.mainMenuWindow)`), задевающее верхнюю полосу экрана.
    public static func fullscreenCheck(
        windows: [ServerWindow], pid: Int32, screen: CGRect, topAllowance: CGFloat,
        menuBarLayer: Int, primaryScreenHeight: CGFloat
    ) -> FullscreenCheck {
        let topStrip = CGRect(
            x: screen.minX, y: screen.maxY - menuBarProbeHeight,
            width: screen.width, height: menuBarProbeHeight
        )
        var covering: CGRect?
        var menuBarVisible = false
        for window in windows {
            let rect = appKitRect(fromWindowServer: window.bounds, primaryScreenHeight: primaryScreenHeight)
            if window.layer == menuBarLayer, overlaps(rect, topStrip) {
                menuBarVisible = true
            } else if covering == nil, window.pid == pid, window.layer == 0,
                      windowCoversScreen(rect, screen: screen, topAllowance: topAllowance) {
                covering = rect
            }
        }
        return FullscreenCheck(coveringWindow: covering, menuBarVisible: menuBarVisible)
    }

    /// Пересечение с ненулевой площадью. `CGRect.intersects` в Foundation на Linux считает
    /// пересечением и касание краями, на Darwin нет; здесь одинаково везде.
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    private static func centeredNotch(size: CGSize, top: CGFloat, in frame: CGRect) -> CGRect {
        CGRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}

/// Окно из `CGWindowListCopyWindowInfo`: владелец, слой и рамка в координатах CGWindow
/// (начало сверху слева основного экрана, ось Y вниз).
public struct ServerWindow: Sendable, Equatable {
    public var pid: Int32
    public var layer: Int
    public var bounds: CGRect

    public init(pid: Int32, layer: Int, bounds: CGRect) {
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
    }
}

/// Результат `NotchGeometry.fullscreenCheck`: оба признака отдельно, для лога.
public struct FullscreenCheck: Sendable, Equatable {
    /// Окно переднего приложения во весь экран (координаты AppKit) или `nil`.
    public var coveringWindow: CGRect?
    /// У верха экрана видна строка меню.
    public var menuBarVisible: Bool

    public var isFullscreen: Bool { coveringWindow != nil && !menuBarVisible }

    public init(coveringWindow: CGRect?, menuBarVisible: Bool) {
        self.coveringWindow = coveringWindow
        self.menuBarVisible = menuBarVisible
    }
}
