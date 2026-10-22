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
    /// Самое широкое крыло на этом экране. У настоящего выреза: свободная область строки меню
    /// с узкой стороны минус `NotchGeometry.wingAuxMargin`, не больше `maxWingWidth`.
    /// У условного выреза и капсулы: `maxWingWidth`.
    public var wingLimit: CGFloat
    /// Ширина крыла из настроек сейчас (ограничивается в `collapsedIsland`). По ней панель
    /// ровно такой ширины, какая нужна, а не под самое широкое крыло.
    public var wingWidth: CGFloat
    /// «Радиус свечения» из настроек сейчас: по нему запас панели под свечение.
    public var glowRadius: Double

    public init(
        screenID: UInt32, screenFrame: CGRect, hasNotch: Bool, notch: CGRect,
        wingLimit: CGFloat = NotchGeometry.maxWingWidth,
        wingWidth: CGFloat = CGFloat(WaveAppearance.standard.wingWidth),
        glowRadius: Double = WaveAppearance.standard.glowRadius
    ) {
        self.screenID = screenID
        self.screenFrame = screenFrame
        self.hasNotch = hasNotch
        self.notch = notch
        self.wingLimit = wingLimit
        self.wingWidth = wingWidth
        self.glowRadius = glowRadius
    }

    /// Свернутый остров: вырез плюс крылья по бокам, крыло не шире `wingLimit` и
    /// `maxWingWidth`. Верх и высота как у выреза. У капсулы крыльев нет: свернутая капсула
    /// ровно `NotchGeometry.pillSize`.
    public func collapsedIsland(wingWidth: CGFloat) -> CGRect {
        let limit = wingLimit.isNaN ? 0 : min(max(wingLimit, 0), NotchGeometry.maxWingWidth)
        let wing = hasNotch && !wingWidth.isNaN ? min(max(wingWidth, 0), limit) : 0
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

    /// Размер баннера нового трека. У выреза: `NotchGeometry.bannerSize` (под вырез 32 pt),
    /// под более высокий вырез выше на разницу. У капсулы: `NotchGeometry.bannerSize`.
    public var bannerSize: CGSize {
        CGSize(width: NotchGeometry.bannerSize.width, height: NotchGeometry.bannerSize.height + bannerExtra)
    }

    /// Баннер нового трека: `bannerSize` по центру выреза (у капсулы по центру капсулы, под
    /// строкой меню), верх на уровне верха выреза или капсулы, как у раскрытого острова.
    public var bannerIsland: CGRect {
        let size = bannerSize
        return CGRect(
            x: notch.midX - size.width / 2, y: notch.maxY - size.height,
            width: size.width, height: size.height
        )
    }

    /// Рамка формы баннера: у выреза шире видимого тела `bannerIsland` на вогнутые плечи
    /// `NotchGeometry.bannerShoulderRadius` с каждой стороны (как `expandedIsland`), поэтому тело
    /// остается 400 pt, а содержимое в 16 pt от его краев. У капсулы плеч нет: `bannerIsland`.
    public var bannerFrame: CGRect {
        hasNotch ? bannerIsland.insetBy(dx: -NotchGeometry.bannerShoulderRadius, dy: 0) : bannerIsland
    }

    /// Раскладка содержимого баннера в его локальных координатах: начало сверху слева
    /// `bannerIsland`, ось Y вниз. Обложка слева, текст под вырезом, волны в полосе справа от
    /// выреза. У капсулы те же прямоугольники, что у условного выреза 32 pt
    /// (`NotchGeometry.fakeNotchSize`), только самого выреза нет.
    public var bannerContent: BannerLayout {
        let width = NotchGeometry.bannerSize.width
        let inset = NotchGeometry.bannerInset
        let notchHeight = NotchGeometry.baseNotchHeight + bannerExtra
        let notchRight = hasNotch
            ? notch.maxX - bannerIsland.minX
            : (width + NotchGeometry.fakeNotchSize.width) / 2
        let artwork = NotchGeometry.bannerArtworkSize
        let artworkTop = (NotchGeometry.bannerSize.height - artwork) / 2
        let textLeft = inset + artwork + 12
        let textTop = notchHeight + 8
        let textBottom = NotchGeometry.bannerSize.height - 8 + bannerExtra
        let wavesLeft = notchRight + 10
        return BannerLayout(
            artwork: CGRect(x: inset, y: artworkTop, width: artwork, height: artwork),
            text: CGRect(x: textLeft, y: textTop, width: width - inset - textLeft, height: textBottom - textTop),
            waves: CGRect(x: wavesLeft, y: 4, width: max(width - inset - wavesLeft, 0), height: notchHeight - 8)
        )
    }

    /// На сколько вырез выше 32 pt: на столько выше баннер. У капсулы 0.
    private var bannerExtra: CGFloat {
        hasNotch ? max(notch.height - NotchGeometry.baseNotchHeight, 0) : 0
    }

    /// Рамка панели: раскрытый и свернутый остров с текущим крылом плюс запас снизу под
    /// свечение текущего радиуса (`NotchGeometry.glowMargin(radius:)`) и по бокам под тень и
    /// «вздох», по горизонтали не выходит за экран. Баннер (`bannerFrame`) в объединении для
    /// надежности: он и так внутри раскрытого острова. Окно не больше, чем нужно сейчас: прозрачная
    /// площадь тоже стоит времени композитору. При настройках по умолчанию рамка та же, что в 0.9.0.
    public var panelFrame: CGRect {
        let union = expandedIsland.union(collapsedIsland(wingWidth: wingWidth)).union(bannerFrame)
        let glow = NotchGeometry.glowMargin(radius: glowRadius)
        let minX = max(union.minX - NotchGeometry.panelSideMargin, screenFrame.minX)
        let maxX = min(union.maxX + NotchGeometry.panelSideMargin, screenFrame.maxX)
        return CGRect(
            x: minX, y: union.minY - glow,
            width: max(maxX - minX, 0), height: union.height + glow
        )
    }

    /// Зона наведения. Свернутая: вырез, продленный до верха экрана, без крыльев. Раскрытая:
    /// раскрытый остров (в режиме капсулы продленный до верха экрана). Обе зоны выступают
    /// выше экрана на `hoverTopOvershoot`, иначе курсор на самой верхней строке пикселей
    /// (`y == frame.maxY`) не попадал бы в полуоткрытый `CGRect`.
    public func hoverZone(expanded: Bool) -> CGRect {
        hoverZone(over: expanded ? expandedIsland : notch)
    }

    /// `base`, продленный до верха экрана и на `hoverTopOvershoot` выше.
    private func hoverZone(over base: CGRect) -> CGRect {
        let top = max(screenFrame.maxY, base.maxY) + NotchGeometry.hoverTopOvershoot
        return CGRect(x: base.minX, y: base.minY, width: base.width, height: top - base.minY)
    }

    /// Что делать с курсором в точке `point` (глобальные координаты AppKit) при состоянии `state`.
    /// `suppressed`: остров принудительно скрыт (пауза, блокировка экрана, полноэкранное окно)
    /// и на курсор не отвечает, поэтому ни опроса, ни кликов. `banner`: виден баннер нового
    /// трека; пока остров не раскрыт, зона наведения: баннер, продленный до верха экрана.
    /// Клики баннер не принимает и опроса не требует, наведение на него раскрывает панель.
    public func pointer(
        at point: CGPoint, state: IslandState, suppressed: Bool = false, banner: Bool = false
    ) -> NotchPointer {
        let expanded = state == .expanded && !suppressed
        let zone = banner && state != .expanded && !suppressed
            ? hoverZone(over: bannerIsland)
            : hoverZone(expanded: expanded)
        let inHoverZone = zone.contains(point)
        return NotchPointer(
            inHoverZone: inHoverZone,
            acceptsClicks: expanded && expandedClickArea.contains(point),
            needsPolling: expanded
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
    /// Нужен частый опрос курсора: раскрытый остров принимает события мыши, а глобальный
    /// монитор не видит событий над своими окнами. Пока остров не раскрыт, панель пропускает
    /// события и монитор видит движения сам, поэтому курсор, оставленный в вырезе, опроса
    /// не держит.
    public var needsPolling: Bool

    public init(inHoverZone: Bool, acceptsClicks: Bool, needsPolling: Bool) {
        self.inHoverZone = inHoverZone
        self.acceptsClicks = acceptsClicks
        self.needsPolling = needsPolling
    }

    /// Засчитать ли курсор в зону наведения. `inZone`: курсор в зоне по геометрии; `moved`:
    /// пересчет от движения мыши или опроса; `banner`: виден баннер; `wasInZone`: курсор уже
    /// был засчитан в зону. Баннер, появившийся под неподвижным курсором, панель не раскрывает:
    /// курсор засчитывается, только когда сдвинется или войдет в зону заново.
    public static func countsAsHover(inZone: Bool, moved: Bool, banner: Bool, wasInZone: Bool) -> Bool {
        inZone && (moved || !banner || wasInZone)
    }
}

/// Раскладка содержимого баннера нового трека в локальных координатах баннера
/// (начало сверху слева `NotchLayout.bannerIsland`, ось Y вниз).
public struct BannerLayout: Sendable, Equatable {
    /// Обложка 56 pt.
    public var artwork: CGRect
    /// Название и исполнитель, под вырезом.
    public var text: CGRect
    /// Волны в полосе справа от выреза.
    public var waves: CGRect

    public init(artwork: CGRect, text: CGRect, waves: CGRect) {
        self.artwork = artwork
        self.text = text
        self.waves = waves
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
    /// Баннер нового трека под вырез `baseNotchHeight`; под более высокий вырез выше на разницу.
    public static let bannerSize = CGSize(width: 400, height: 84)
    /// Радиус нижних углов баннера.
    public static let bannerBottomRadius: CGFloat = 22
    /// Вогнутые плечи баннера у выреза, как у раскрытой панели (`NotchLayout.bannerFrame`).
    public static let bannerShoulderRadius: CGFloat = expandedShoulderRadius
    /// Отступ содержимого баннера слева и справа.
    static let bannerInset: CGFloat = 16
    /// Сторона обложки в баннере.
    static let bannerArtworkSize: CGFloat = 56
    /// Самое широкое крыло, pt.
    public static let maxWingWidth: CGFloat = 200
    /// Насколько крыло уже свободной области строки меню рядом с вырезом, pt.
    public static let wingAuxMargin: CGFloat = 8
    /// Насколько зона наведения выступает выше верха экрана.
    static let hoverTopOvershoot: CGFloat = 2
    /// Запас под панелью для свечения при «Радиусе свечения» 1× (как в 0.9.0): свечение
    /// размыто на 14 pt и уходит ниже острова примерно на три радиуса размытия.
    public static let glowMargin: CGFloat = 40

    /// Запас под свечение радиуса `radius`: `glowMargin × radius`, радиус в 1...3 (меньший
    /// радиус окно не сужает, не конечный считается 1×). При 3× размытие 42 pt, свечение
    /// уходит ниже острова на 3 × 42 - 6 = 120 pt.
    public static func glowMargin(radius: Double) -> CGFloat {
        let radius = radius.isFinite ? min(max(radius, 1), WaveAppearance.Limits.glowRadius.upperBound) : 1
        return glowMargin * CGFloat(radius)
    }
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
            let freeWidth = max(min(left, right), 0)
            let wingLimit = min(max(freeWidth - wingAuxMargin, 0), maxWingWidth)
            return NotchLayout(
                screenID: screen.id, screenFrame: screen.frame, hasNotch: true, notch: notch, wingLimit: wingLimit
            )
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
