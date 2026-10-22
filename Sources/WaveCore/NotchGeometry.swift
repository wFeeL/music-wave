import Foundation

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

    /// Свернутый остров: вырез плюс крылья по бокам. Верх и высота как у выреза.
    public func collapsedIsland(wingWidth: CGFloat) -> CGRect {
        let wing = min(max(wingWidth, 0), NotchGeometry.maxWingWidth)
        return CGRect(
            x: notch.minX - wing, y: notch.minY,
            width: notch.width + 2 * wing, height: notch.height
        )
    }

    /// Раскрытый остров: `expandedSize` по центру выреза, верх на уровне верха выреза.
    public var expandedIsland: CGRect {
        let size = NotchGeometry.expandedSize
        return CGRect(
            x: notch.midX - size.width / 2, y: notch.maxY - size.height,
            width: size.width, height: size.height
        )
    }

    /// Рамка панели: раскрытый и самый широкий свернутый остров плюс запас снизу под свечение,
    /// по горизонтали не выходит за экран.
    public var panelFrame: CGRect {
        let union = expandedIsland.union(collapsedIsland(wingWidth: NotchGeometry.maxWingWidth))
        let minX = max(union.minX, screenFrame.minX)
        let maxX = min(union.maxX, screenFrame.maxX)
        return CGRect(
            x: minX, y: union.minY - NotchGeometry.glowMargin,
            width: max(maxX - minX, 0), height: union.height + NotchGeometry.glowMargin
        )
    }

    /// Зона наведения: свернутая это вырез, продленный до верха экрана, без крыльев.
    public func hoverZone(expanded: Bool) -> CGRect {
        if expanded { return expandedIsland }
        return CGRect(
            x: notch.minX, y: notch.minY,
            width: notch.width, height: max(screenFrame.maxY, notch.maxY) - notch.minY
        )
    }
}

public enum NotchGeometry {
    public static let expandedSize = CGSize(width: 480, height: 170)
    public static let pillSize = CGSize(width: 200, height: 32)
    public static let maxWingWidth: CGFloat = 120
    /// Запас под панелью для свечения.
    static let glowMargin: CGFloat = 40
    /// Отступ капсулы от строки меню на экране без выреза.
    static let pillGap: CGFloat = 6
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
           let left = screen.auxiliaryLeftWidth, let right = screen.auxiliaryRightWidth {
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

    private static func centeredNotch(size: CGSize, top: CGFloat, in frame: CGRect) -> CGRect {
        CGRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}
