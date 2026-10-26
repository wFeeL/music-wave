import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import WaveCore

struct NotchGeometryTests {
    /// Условный экран с вырезом 185 pt (настоящие размеры читаются на маке владельца).
    private func notched(
        id: UInt32 = 1, frame: CGRect = CGRect(x: 0, y: 0, width: 1470, height: 956),
        left: CGFloat = 642.5, right: CGFloat = 642.5
    ) -> ScreenDescriptor {
        ScreenDescriptor(
            id: id, frame: frame, safeAreaTop: 32,
            auxiliaryLeftWidth: left, auxiliaryRightWidth: right,
            isBuiltIn: true, menuBarHeight: 32
        )
    }

    private func external(
        id: UInt32 = 2, frame: CGRect = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
    ) -> ScreenDescriptor {
        ScreenDescriptor(
            id: id, frame: frame, safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
            isBuiltIn: false, menuBarHeight: 24
        )
    }

    @Test func notchFromAuxiliaryAreas() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        #expect(layout.hasNotch)
        #expect(layout.screenID == 1)
        #expect(layout.notch == CGRect(x: 642.5, y: 924, width: 185, height: 32))
    }

    @Test func asymmetricAuxiliaryAreas() throws {
        let frame = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let layout = try #require(NotchGeometry.layout(for: [notched(frame: frame, left: 751, right: 750)]))
        #expect(layout.notch.minX == 751)
        #expect(layout.notch.width == 209)
        #expect(layout.notch.midX != frame.midX)
    }

    @Test func notchOnScreenWithOffsetOrigin() throws {
        let frame = CGRect(x: -1470, y: 100, width: 1470, height: 956)
        let layout = try #require(NotchGeometry.layout(for: [notched(frame: frame)]))
        #expect(layout.notch == CGRect(x: -827.5, y: 1024, width: 185, height: 32))
    }

    @Test func collapsedIncludesWings() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let island = layout.collapsedIsland(wingWidth: 64)
        #expect(island.width == 313)
        #expect(island.midX == layout.notch.midX)
        #expect(island.height == layout.notch.height)
        #expect(island.maxY == 956)
    }

    @Test func wingWidthIsClamped() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        #expect(layout.collapsedIsland(wingWidth: -5) == layout.notch)
        #expect(layout.collapsedIsland(wingWidth: 500).width == 185 + 2 * NotchGeometry.maxWingWidth)
    }

    @Test func expandedHangsFromTop() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let island = layout.expandedIsland
        #expect(island.maxY == 956)
        #expect(island.width == 486)
        #expect(island.height == 170)
        #expect(island.midX == layout.notch.midX)
        // Видимое тело 468 pt, по бокам вогнутые плечи 9 pt.
        #expect(NotchGeometry.expandedBodyWidth + 2 * NotchGeometry.expandedShoulderRadius == island.width)
        #expect(layout.expandedContentTop == 45)
    }

    @Test func tallerNotchGrowsExpandedPanel() throws {
        var screen = notched()
        screen.safeAreaTop = 38
        screen.menuBarHeight = 38
        let layout = try #require(NotchGeometry.layout(for: [screen]))
        #expect(layout.notch.height == 38)
        #expect(layout.expandedIsland.height == 176)
        #expect(layout.expandedIsland.width == 486)
        #expect(layout.expandedIsland.maxY == 956)
        #expect(layout.expandedContentTop == 51)
        // Под содержимым столько же места, сколько у выреза 32 pt.
        let below = layout.expandedIsland.height - layout.expandedContentTop
        let base = try #require(NotchGeometry.layout(for: [notched()]))
        #expect(below == base.expandedIsland.height - base.expandedContentTop)
    }

    @Test func contentClearsNotchByAtLeast12() throws {
        for height: CGFloat in [24, 30, 32, 33, 37.5, 38, 44] {
            var screen = notched()
            screen.safeAreaTop = height
            let layout = try #require(NotchGeometry.layout(for: [screen]))
            #expect(layout.expandedContentTop - layout.notch.height >= 12, "вырез \(height)")
            #expect(layout.expandedIsland.height >= 170)
        }
    }

    @Test func pillExpandedIsCompact() throws {
        let layout = try #require(NotchGeometry.layout(for: [external()]))
        #expect(layout.expandedIsland.size == CGSize(width: 468, height: 150))
        #expect(layout.expandedIsland.midX == layout.notch.midX)
        #expect(layout.expandedContentTop == 16)
    }

    @Test func hoverZoneExcludesWings() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let zone = layout.hoverZone(expanded: false)
        #expect(zone.minX == layout.notch.minX)
        #expect(zone.maxX == layout.notch.maxX)
        let left = CGPoint(x: layout.notch.minX - 10, y: layout.notch.midY)
        let right = CGPoint(x: layout.notch.maxX + 10, y: layout.notch.midY)
        let leftTop = CGPoint(x: layout.notch.minX - 10, y: 956 - 1)
        let rightTop = CGPoint(x: layout.notch.maxX + 10, y: 956 - 1)
        #expect(!zone.contains(left))
        #expect(!zone.contains(right))
        #expect(!zone.contains(leftTop))
        #expect(!zone.contains(rightTop))
        #expect(zone.contains(CGPoint(x: layout.notch.midX, y: layout.notch.midY)))
        #expect(layout.hoverZone(expanded: true).minX == layout.expandedIsland.minX)
        #expect(layout.hoverZone(expanded: true).maxX == layout.expandedIsland.maxX)
    }

    @Test func hoverZoneIncludesScreenTopEdge() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let top = CGPoint(x: layout.notch.midX, y: layout.screenFrame.maxY)
        #expect(layout.hoverZone(expanded: false).contains(top))
        #expect(layout.hoverZone(expanded: true).contains(top))
    }

    @Test func pillHoverZonesIncludeScreenTopEdge() throws {
        let layout = try #require(NotchGeometry.layout(for: [external()]))
        let top = CGPoint(x: layout.notch.midX, y: layout.screenFrame.maxY)
        #expect(layout.hoverZone(expanded: false).contains(top))
        #expect(layout.hoverZone(expanded: true).contains(top))
        #expect(layout.hoverZone(expanded: true).contains(CGPoint(x: layout.notch.midX, y: layout.expandedIsland.minY)))
    }

    @Test func degenerateAuxiliaryWidthsFallBackToPill() throws {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let layout = try #require(NotchGeometry.layout(for: [notched(frame: frame, left: 735, right: 735)]))
        #expect(!layout.hasNotch)
        #expect(layout.notch.size == NotchGeometry.pillSize)
        let wider = try #require(NotchGeometry.layout(for: [notched(frame: frame, left: 800, right: 800)]))
        #expect(!wider.hasNotch)
    }

    @Test func prefersBuiltInNotchedScreen() throws {
        let layout = try #require(NotchGeometry.layout(for: [external(), notched()]))
        #expect(layout.screenID == 1)
        #expect(layout.hasNotch)
    }

    @Test func externalOnlyGivesPill() throws {
        let screen = external()
        let layout = try #require(NotchGeometry.layout(for: [screen]))
        #expect(!layout.hasNotch)
        #expect(layout.screenID == 2)
        #expect(layout.notch.size == NotchGeometry.pillSize)
        #expect(layout.notch.midX == screen.frame.midX)
        #expect(layout.notch.maxY == screen.frame.maxY - 24 - 8)
        #expect(NotchGeometry.pillSize == CGSize(width: 240, height: 28))
    }

    @Test func pillExpandedHangsFromPillTop() throws {
        let screen = external()
        let layout = try #require(NotchGeometry.layout(for: [screen]))
        #expect(layout.expandedIsland.maxY == layout.notch.maxY)
        #expect(layout.collapsedIsland(wingWidth: 40).maxY == layout.notch.maxY)
        let hover = layout.hoverZone(expanded: false)
        #expect(hover.maxY == screen.frame.maxY + NotchGeometry.hoverTopOvershoot)
        #expect(hover.minY == layout.notch.minY)
        #expect(hover.minX == layout.notch.minX)
        #expect(hover.width == layout.notch.width)
    }

    @Test func fakeNotchOnPlainScreen() throws {
        let screen = external()
        let layout = try #require(NotchGeometry.layout(for: [screen], fakeNotch: true))
        #expect(layout.hasNotch)
        #expect(layout.screenID == 2)
        #expect(layout.notch == CGRect(x: screen.frame.midX - 92.5, y: screen.frame.maxY - 32, width: 185, height: 32))
    }

    @Test func fakeNotchUsesFirstScreen() throws {
        let layout = try #require(NotchGeometry.layout(for: [external(), notched()], fakeNotch: true))
        #expect(layout.screenID == 2)
    }

    @Test func emptyScreensGiveNil() {
        #expect(NotchGeometry.layout(for: []) == nil)
        #expect(NotchGeometry.layout(for: [], fakeNotch: true) == nil)
    }

    @Test func panelContainsEverything() throws {
        var layout = try #require(NotchGeometry.layout(for: [notched()]))
        layout.wingWidth = NotchGeometry.maxWingWidth
        let panel = layout.panelFrame
        #expect(panel.contains(layout.expandedIsland))
        #expect(panel.contains(layout.collapsedIsland(wingWidth: NotchGeometry.maxWingWidth)))
        #expect(panel.minY == layout.expandedIsland.minY - NotchGeometry.glowMargin)
        #expect(panel.maxY == 956)
        // Запас по бокам под тень и «вздох».
        #expect(panel.minX == layout.collapsedIsland(wingWidth: 200).minX - NotchGeometry.panelSideMargin)
        #expect(panel.maxX == layout.collapsedIsland(wingWidth: 200).maxX + NotchGeometry.panelSideMargin)
        #expect(NotchGeometry.panelSideMargin == 24)
        // Клики только над самим раскрытым островом, не над запасом.
        let margin = CGPoint(x: panel.minX + 4, y: layout.expandedIsland.midY)
        #expect(!layout.pointer(at: margin, state: .expanded).acceptsClicks)
    }

    /// Крыло не шире свободной области строки меню у выреза минус 8 pt, и клики через него идут
    /// в строку меню.
    @Test func wingIsLimitedToAuxiliaryAreaAndPassesClicks() throws {
        #expect(NotchGeometry.maxWingWidth == 200)
        #expect(NotchGeometry.wingAuxMargin == 8)
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let narrow = try #require(NotchGeometry.layout(for: [notched(frame: frame, left: 150, right: 300)]))
        #expect(narrow.wingLimit == 142)
        #expect(narrow.collapsedIsland(wingWidth: 200).width == narrow.notch.width + 2 * 142)
        #expect(narrow.collapsedIsland(wingWidth: 100).width == narrow.notch.width + 2 * 100)

        let wide = try #require(NotchGeometry.layout(for: [notched(frame: frame, left: 640, right: 640)]))
        #expect(wide.wingLimit == 200)
        let island = wide.collapsedIsland(wingWidth: 200)
        #expect(island.width == wide.notch.width + 2 * 200)
        let rightWing = CGPoint(x: wide.notch.maxX + 100, y: wide.notch.midY)
        for state in [IslandState.hidden, .collapsed] {
            let pointer = wide.pointer(at: rightWing, state: state)
            #expect(!pointer.inHoverZone && !pointer.acceptsClicks)
        }

        // Капсула и условный вырез: предел по умолчанию.
        let fake = try #require(NotchGeometry.layout(for: [external()], fakeNotch: true))
        #expect(fake.wingLimit == 200)
        #expect(fake.collapsedIsland(wingWidth: 200).width == fake.notch.width + 400)
        #expect(try #require(NotchGeometry.layout(for: [external()])).wingLimit == 200)
        #expect(NotchLayout(screenID: 1, screenFrame: frame, hasNotch: true, notch: wide.notch).wingLimit == 200)
    }

    @Test func negativeAuxiliaryWidthIsGuarded() throws {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let layout = try #require(NotchGeometry.layout(for: [notched(frame: frame, left: -20, right: 640)]))
        #expect(layout.wingLimit == 0)
        #expect(layout.collapsedIsland(wingWidth: 120) == layout.notch)
    }

    /// При настройках по умолчанию (крыло 64 pt, радиус 1×) панель того же размера, что в
    /// 0.9.0: 534 × 210 pt (раскрытый остров 486 × 170, по 24 pt по бокам, 40 pt под свечение).
    @Test func panelFrameAtDefaultsMatches090() throws {
        #expect(NotchGeometry.glowMargin == 40)
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        #expect(layout.wingWidth == 64)
        #expect(layout.glowRadius == 1)
        let panel = layout.panelFrame
        #expect(panel.size == CGSize(width: 534, height: 210))
        #expect(panel.midX == layout.notch.midX)
        #expect(panel.maxY == 956)
        #expect(panel.contains(layout.collapsedIsland(wingWidth: 64)))
        // Узкий радиус окно не сужает, мусор считается 1×.
        for radius in [0.5, -1, .nan, .infinity] {
            var other = layout
            other.glowRadius = radius
            #expect(other.panelFrame == panel, "радиус \(radius)")
        }
        // Крыло до 150 pt уже раскрытого острова: ширина та же.
        var wider = layout
        wider.wingWidth = 150
        #expect(wider.panelFrame == panel)
        // Панель капсулы как в 0.9.0, плюс поле сверху под свечение обложки (1.2).
        let pill = try #require(NotchGeometry.layout(for: [external()]))
        #expect(pill.panelFrame.size == CGSize(width: 468 + 48, height: 150 + 40 + 20))
    }

    /// Свечение обложки с размытием помещается в окно панели со всех сторон: по бокам, снизу
    /// и сверху. У выреза верх панели это верх экрана, выше рисовать нечего, рамка та же, что
    /// в 0.9.0; над капсулой поле `panelTopMargin`.
    @Test func artworkHaloFitsPanelFrame() throws {
        for screen in [notched(), external()] {
            for wing: CGFloat in [0, 64, 200] {
                for radius in [1.0, 3.0] {
                    var layout = try #require(NotchGeometry.layout(for: [screen]))
                    layout.wingWidth = wing
                    layout.glowRadius = radius
                    let blur = CGFloat(2 * ArtworkGlow.blur)
                    let extent = ArtworkGlow.halo(around: layout.expandedClickArea).insetBy(dx: -blur, dy: -blur)
                    #expect(
                        layout.panelFrame.contains(extent.intersection(layout.screenFrame)),
                        "\(screen.id), крыло \(wing), радиус \(radius)"
                    )
                }
            }
        }
        let pill = try #require(NotchGeometry.layout(for: [external()]))
        #expect(pill.panelFrame.maxY == pill.expandedIsland.maxY + NotchGeometry.panelTopMargin)
        let notch = try #require(NotchGeometry.layout(for: [notched()]))
        #expect(notch.panelFrame.maxY == notch.screenFrame.maxY)
    }

    /// Свечение радиусом 3× помещается: размытие 42 pt (14 × 3) уходит ниже острова примерно на
    /// три радиуса минус подъем 6 pt.
    @Test func panelFrameFitsTripleGlow() throws {
        var layout = try #require(NotchGeometry.layout(for: [notched()]))
        layout.glowRadius = 3
        let panel = layout.panelFrame
        let blur: CGFloat = 14 * 3
        #expect(layout.expandedIsland.minY - panel.minY >= 3 * blur - 6)
        #expect(panel.minY == layout.expandedIsland.minY - 120)
        #expect(panel.maxY == 956)
        #expect(panel.width == 534)
        layout.glowRadius = 9
        #expect(layout.panelFrame == panel)
    }

    /// Крылья 200 pt помещаются целиком с запасом по бокам, высота не меняется.
    @Test func panelFrameFitsWidestWing() throws {
        var layout = try #require(NotchGeometry.layout(for: [notched()]))
        layout.wingWidth = 200
        let widest = layout.collapsedIsland(wingWidth: 200)
        let panel = layout.panelFrame
        #expect(panel.contains(widest))
        #expect(panel.minX == widest.minX - 24)
        #expect(panel.maxX == widest.maxX + 24)
        #expect(abs(panel.width - (185 + 400 + 48)) < 1e-9)
        #expect(panel.height == 210)
        // Крыло шире свободной области ограничено ею, и панель вместе с ним.
        let narrow = try #require(NotchGeometry.layout(for: [notched(left: 150, right: 300)]))
        var limited = narrow
        limited.wingWidth = 200
        #expect(limited.panelFrame.contains(narrow.collapsedIsland(wingWidth: 142)))
        var atLimit = narrow
        atLimit.wingWidth = 142
        #expect(limited.panelFrame == atLimit.panelFrame)
        // Клики и наведение от крыльев и панели не зависят.
        let rightWing = CGPoint(x: layout.notch.maxX + 100, y: layout.notch.midY)
        #expect(!layout.pointer(at: rightWing, state: .collapsed).inHoverZone)
        #expect(!layout.pointer(at: rightWing, state: .collapsed).acceptsClicks)
        #expect(layout.expandedClickArea == NotchGeometry.layout(for: [notched()])?.expandedClickArea)
    }

    @Test func collapsedPillHasNoWings() throws {
        let layout = try #require(NotchGeometry.layout(for: [external()]))
        for wing: CGFloat in [0, 40, 64, 120] {
            #expect(layout.collapsedIsland(wingWidth: wing) == layout.notch)
        }
        #expect(layout.collapsedIsland(wingWidth: 64).size == NotchGeometry.pillSize)
        let panel = layout.panelFrame
        #expect(panel.minX == layout.expandedIsland.minX - NotchGeometry.panelSideMargin)
    }

    @Test func panelIsClampedToScreen() throws {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 956)
        let layout = try #require(NotchGeometry.layout(for: [notched(frame: frame, left: 107.5, right: 107.5)]))
        #expect(layout.panelFrame.minX == 0)
        #expect(layout.panelFrame.maxX == 400)
    }

    // MARK: - Курсор

    @Test func collapsedNeverAcceptsClicks() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        for state in [IslandState.hidden, .collapsed] {
            for point in [
                CGPoint(x: layout.notch.midX, y: layout.notch.midY),
                CGPoint(x: layout.expandedIsland.midX, y: layout.expandedIsland.midY),
                CGPoint(x: layout.notch.minX - 10, y: 950),
            ] {
                #expect(!layout.pointer(at: point, state: state).acceptsClicks)
            }
        }
    }

    /// Свернутый остров не опрашивает курсор, даже когда тот стоит в вырезе: панель пропускает
    /// события, и глобальный монитор видит движения сам.
    @Test func pointerOverCollapsedNotchNeedsNoPolling() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let point = CGPoint(x: layout.notch.midX, y: 956)
        for state in [IslandState.hidden, .collapsed] {
            let pointer = layout.pointer(at: point, state: state)
            #expect(pointer == NotchPointer(inHoverZone: true, acceptsClicks: false, needsPolling: false))
        }
    }

    @Test func pointerOverWingsAndMenuBarIsIgnored() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let wing = CGPoint(x: layout.notch.minX - 10, y: layout.notch.midY)
        let statusItem = CGPoint(x: layout.notch.maxX + 40, y: 955)
        for point in [wing, statusItem] {
            #expect(layout.pointer(at: point, state: .collapsed) == NotchPointer(
                inHoverZone: false, acceptsClicks: false, needsPolling: false
            ))
        }
    }

    @Test func shoulderStripsDoNotAcceptClicks() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let island = layout.expandedIsland
        let shoulder = NotchGeometry.expandedShoulderRadius
        #expect(layout.expandedClickArea == island.insetBy(dx: shoulder, dy: 0))
        #expect(layout.expandedClickArea.width == NotchGeometry.expandedBodyWidth)
        // Полосы под плечами прозрачны, частью лежат на строке меню: клики идут мимо.
        for x in [island.minX + 1, island.minX + shoulder - 1, island.maxX - 1, island.maxX - shoulder + 1] {
            for y in [island.maxY - 1, island.midY, island.minY + 1] {
                let pointer = layout.pointer(at: CGPoint(x: x, y: y), state: .expanded)
                #expect(!pointer.acceptsClicks, "x \(x), y \(y)")
                #expect(pointer.inHoverZone, "x \(x), y \(y)")
            }
        }
        #expect(layout.pointer(at: CGPoint(x: island.minX + shoulder + 1, y: island.midY), state: .expanded).acceptsClicks)
        // У капсулы плеч нет: кликабельна вся панель.
        let pill = try #require(NotchGeometry.layout(for: [external()]))
        #expect(pill.expandedClickArea == pill.expandedIsland)
    }

    @Test func expandedAcceptsClicksOnlyInsideIsland() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let island = layout.expandedIsland
        let inside = layout.pointer(at: CGPoint(x: island.minX + 12, y: island.minY + 5), state: .expanded)
        #expect(inside == NotchPointer(inHoverZone: true, acceptsClicks: true, needsPolling: true))
        let below = layout.pointer(at: CGPoint(x: island.midX, y: island.minY - 5), state: .expanded)
        #expect(below == NotchPointer(inHoverZone: false, acceptsClicks: false, needsPolling: true))
        let aside = layout.pointer(at: CGPoint(x: island.maxX + 5, y: island.midY), state: .expanded)
        #expect(!aside.acceptsClicks)
        #expect(aside.needsPolling)
    }

    // MARK: - Полноэкранные окна

    @Test func windowServerRectToAppKit() {
        // Основной экран 1470 × 956; окно 100 × 50 в 10 pt от левого и 20 pt от верхнего края.
        let rect = NotchGeometry.appKitRect(
            fromWindowServer: CGRect(x: 10, y: 20, width: 100, height: 50), primaryScreenHeight: 956
        )
        #expect(rect == CGRect(x: 10, y: 886, width: 100, height: 50))
    }

    @Test func windowServerRectOnSecondaryScreenAbove() {
        // Второй экран 1920 × 1080 стоит над основным: в AppKit y от 956, в CGWindow y отрицательный.
        let rect = NotchGeometry.appKitRect(
            fromWindowServer: CGRect(x: 0, y: -1080, width: 1920, height: 1080), primaryScreenHeight: 956
        )
        #expect(rect == CGRect(x: 0, y: 956, width: 1920, height: 1080))
    }

    @Test func fullFrameWindowCoversScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        #expect(NotchGeometry.windowCoversScreen(screen, screen: screen, topAllowance: 32))
        #expect(NotchGeometry.windowCoversScreen(screen.insetBy(dx: -0.5, dy: -0.5), screen: screen, topAllowance: 0))
    }

    @Test func windowBelowNotchCoversScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let belowNotch = CGRect(x: 0, y: 0, width: 1470, height: 924)
        #expect(NotchGeometry.windowCoversScreen(belowNotch, screen: screen, topAllowance: 32))
        #expect(!NotchGeometry.windowCoversScreen(belowNotch, screen: screen, topAllowance: 0))
    }

    @Test func ordinaryWindowsDoNotCoverScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let zoomedAboveDock = CGRect(x: 0, y: 70, width: 1470, height: 854)
        let narrower = CGRect(x: 10, y: 0, width: 1460, height: 956)
        let otherScreen = CGRect(x: 1470, y: 0, width: 1470, height: 956)
        for window in [zoomedAboveDock, narrower, otherScreen] {
            #expect(!NotchGeometry.windowCoversScreen(window, screen: screen, topAllowance: 32))
        }
    }

    // MARK: - Полноэкранный режим: окно и строка меню

    private static let appPID: Int32 = 42
    private static let menuBarLayer = 24

    /// Окно в координатах CGWindow на экране `notched()` (основной, высота 956).
    private func server(_ rect: CGRect, pid: Int32 = appPID, layer: Int = 0) -> ServerWindow {
        ServerWindow(pid: pid, layer: layer, bounds: rect)
    }

    /// Строка меню экрана `notched()`: высота как `menuBarHeight` фикстуры, 32 pt.
    private var menuBar: ServerWindow {
        server(CGRect(x: 0, y: 0, width: 1470, height: 32), pid: 0, layer: Self.menuBarLayer)
    }

    private func check(_ windows: [ServerWindow]) -> FullscreenCheck {
        NotchGeometry.fullscreenCheck(
            windows: windows, pid: Self.appPID, screen: CGRect(x: 0, y: 0, width: 1470, height: 956), topAllowance: 32,
            menuBarLayer: Self.menuBarLayer, primaryScreenHeight: 956
        )
    }

    @Test func zoomedWindowUnderMenuBarIsNotFullscreen() {
        // Окно растянуто под строкой меню, Dock скрыт: по рамке не отличить от полноэкранного.
        let zoomed = server(CGRect(x: 0, y: 32, width: 1470, height: 924))
        let result = check([menuBar, zoomed])
        #expect(result.coveringWindow == CGRect(x: 0, y: 0, width: 1470, height: 924))
        #expect(result.menuBarVisible)
        #expect(!result.isFullscreen)
    }

    @Test func coveringWindowWithoutMenuBarIsFullscreen() {
        let fullFrame = check([server(CGRect(x: 0, y: 0, width: 1470, height: 956))])
        #expect(fullFrame == FullscreenCheck(coveringWindow: CGRect(x: 0, y: 0, width: 1470, height: 956), menuBarVisible: false))
        #expect(fullFrame.isFullscreen)
        let belowNotch = check([server(CGRect(x: 0, y: 32, width: 1470, height: 924))])
        #expect(belowNotch.isFullscreen)
    }

    @Test func menuBarSlidOutAboveScreenDoesNotCount() {
        let hidden = server(CGRect(x: 0, y: -32, width: 1470, height: 32), pid: 0, layer: Self.menuBarLayer)
        let result = check([hidden, server(CGRect(x: 0, y: 0, width: 1470, height: 956))])
        #expect(!result.menuBarVisible)
        #expect(result.isFullscreen)
    }

    @Test func menuBarOfOtherDisplayDoesNotCount() {
        let otherMenuBar = server(CGRect(x: 1470, y: 0, width: 1920, height: 24), pid: 0, layer: Self.menuBarLayer)
        let result = check([otherMenuBar, server(CGRect(x: 0, y: 0, width: 1470, height: 956))])
        #expect(!result.menuBarVisible)
        #expect(result.isFullscreen)
    }

    @Test func otherAppsAndLayersAreIgnored() {
        let full = CGRect(x: 0, y: 0, width: 1470, height: 956)
        #expect(check([server(full, pid: 7)]).coveringWindow == nil)
        #expect(check([server(full, layer: 3)]).coveringWindow == nil)
        #expect(!check([server(full, pid: 7), server(full, layer: 3)]).isFullscreen)
        #expect(!check([]).isFullscreen)
    }

    @Test func ordinaryWindowsWithMenuBarAreNotFullscreen() {
        for rect in [
            CGRect(x: 0, y: 32, width: 1470, height: 854),
            CGRect(x: 0, y: 32, width: 1470, height: 924),
            CGRect(x: 100, y: 100, width: 800, height: 600),
        ] {
            #expect(!check([menuBar, server(rect)]).isFullscreen)
        }
    }

    // MARK: - Подавленный остров

    @Test func suppressedIslandNeitherPollsNorAcceptsClicks() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let center = CGPoint(x: layout.expandedIsland.midX, y: layout.expandedIsland.maxY - 5)
        for state in [IslandState.hidden, .collapsed, .expanded] {
            let pointer = layout.pointer(at: center, state: state, suppressed: true)
            #expect(pointer.inHoverZone)
            #expect(!pointer.acceptsClicks)
            #expect(!pointer.needsPolling)
        }
    }

    // MARK: - Баннер нового трека

    /// Прямоугольник из локальных координат баннера (начало сверху слева, ось Y вниз)
    /// в координаты экрана.
    private func onScreen(_ rect: CGRect, in banner: CGRect) -> CGRect {
        CGRect(x: banner.minX + rect.minX, y: banner.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Пересечение с ненулевой площадью (на Linux `intersects` считает и касание краями).
    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    @Test func bannerSitsUnderNotch() throws {
        #expect(NotchGeometry.bannerSize == CGSize(width: 400, height: 84))
        #expect(NotchGeometry.bannerBottomRadius == 22)
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let banner = layout.bannerIsland
        #expect(banner.size == CGSize(width: 400, height: 84))
        #expect(banner.midX == layout.notch.midX)
        #expect(banner.maxY == layout.notch.maxY)
        let asymmetric = try #require(
            NotchGeometry.layout(for: [notched(frame: CGRect(x: 0, y: 0, width: 1710, height: 1107), left: 751, right: 750)])
        )
        #expect(asymmetric.bannerIsland.midX == asymmetric.notch.midX)
        #expect(asymmetric.bannerIsland.maxY == 1107)
    }

    @Test func bannerGrowsWithTallerNotch() throws {
        var screen = notched()
        screen.safeAreaTop = 38
        screen.menuBarHeight = 38
        let layout = try #require(NotchGeometry.layout(for: [screen]))
        #expect(layout.bannerIsland.size == CGSize(width: 400, height: 90))
        #expect(layout.bannerIsland.maxY == 956)
        let content = layout.bannerContent
        #expect(content.artwork == CGRect(x: 16, y: 23, width: 56, height: 56))
        #expect(content.text.minY == 46)
        #expect(content.text.maxY == 80)
        #expect(content.waves.minY == 4)
        #expect(content.waves.maxY == 34)
    }

    @Test func bannerContentMatchesSpec() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let content = layout.bannerContent
        #expect(content.artwork == CGRect(x: 16, y: 17, width: 56, height: 56))
        #expect(content.text == CGRect(x: 84, y: 40, width: 300, height: 34))
        let wavesStart = layout.notch.maxX - layout.bannerIsland.minX + 10
        #expect(content.waves == CGRect(x: wavesStart, y: 4, width: 384 - wavesStart, height: 24))
    }

    @Test func bannerContentAvoidsNotch() throws {
        for height: CGFloat in [32, 34, 38] {
            for (left, right): (CGFloat, CGFloat) in [(642.5, 642.5), (620, 640), (660, 600)] {
                var screen = notched(left: left, right: right)
                screen.safeAreaTop = height
                let layout = try #require(NotchGeometry.layout(for: [screen]))
                let banner = layout.bannerIsland
                let content = layout.bannerContent
                for (name, rect) in [("artwork", content.artwork), ("text", content.text), ("waves", content.waves)] {
                    let placed = onScreen(rect, in: banner)
                    #expect(rect.width > 0 && rect.height > 0, "\(name), вырез \(height)")
                    #expect(!overlaps(placed, layout.notch), "\(name), вырез \(height), \(left)/\(right)")
                    #expect(banner.contains(placed), "\(name), вырез \(height), \(left)/\(right)")
                }
                #expect(!overlaps(content.artwork, content.text))
                #expect(!overlaps(content.artwork, content.waves))
                #expect(!overlaps(content.text, content.waves))
            }
        }
    }

    @Test func pillBannerHangsFromPillTop() throws {
        let layout = try #require(NotchGeometry.layout(for: [external()]))
        let banner = layout.bannerIsland
        #expect(banner.size == NotchGeometry.bannerSize)
        #expect(banner.midX == layout.notch.midX)
        #expect(banner.maxY == layout.notch.maxY)
        #expect(banner.maxY < layout.screenFrame.maxY - 24)
        // Те же прямоугольники, что у выреза 32 pt, только без выреза.
        let reference = try #require(NotchGeometry.layout(for: [external()], fakeNotch: true))
        #expect(layout.bannerContent == reference.bannerContent)
        for rect in [layout.bannerContent.artwork, layout.bannerContent.text, layout.bannerContent.waves] {
            #expect(banner.contains(onScreen(rect, in: banner)))
        }
    }

    @Test func hoverOverBannerCounts() throws {
        for screen in [notched(), external()] {
            let layout = try #require(NotchGeometry.layout(for: [screen]))
            let banner = layout.bannerIsland
            let text = onScreen(layout.bannerContent.text, in: banner)
            let point = CGPoint(x: text.midX, y: text.midY)
            for state in [IslandState.hidden, .collapsed] {
                let shown = layout.pointer(at: point, state: state, banner: true)
                #expect(shown.inHoverZone)
                #expect(shown.acceptsClicks == (state == .collapsed))
                #expect(shown.needsPolling == (state == .collapsed))
                let plain = layout.pointer(at: point, state: state, banner: false)
                #expect(!plain.inHoverZone)
                #expect(!plain.acceptsClicks)
            }
            // Зона доходит до верха экрана и не шире баннера.
            let top = CGPoint(x: banner.midX, y: layout.screenFrame.maxY)
            #expect(layout.pointer(at: top, state: .collapsed, banner: true).inHoverZone)
            let beside = CGPoint(x: banner.maxX + 1, y: text.midY)
            #expect(!layout.pointer(at: beside, state: .collapsed, banner: true).inHoverZone)
            let below = CGPoint(x: banner.midX, y: banner.minY - 1)
            #expect(!layout.pointer(at: below, state: .collapsed, banner: true).inHoverZone)
            // Раскрытый остров баннер не меняет.
            let center = CGPoint(x: layout.expandedIsland.midX, y: layout.expandedIsland.midY)
            #expect(
                layout.pointer(at: center, state: .expanded, banner: true)
                    == layout.pointer(at: center, state: .expanded)
            )
        }
    }

    /// Баннер над свернутым островом принимает клики видимым телом, в том числе частью под
    /// строкой меню, чтобы клик не ушел в окно под баннером. Прозрачные полосы под плечами,
    /// все вокруг и баннер, который уже не виден, клики пропускают. Опрос идет, пока баннер
    /// виден, и где бы ни был курсор: окно пропускает события только вне тела баннера.
    @Test func bannerBodyAcceptsClicksOverCollapsedIsland() throws {
        var tall = notched()
        tall.safeAreaTop = 38
        for screen in [notched(), tall, external()] {
            let layout = try #require(NotchGeometry.layout(for: [screen]))
            let body = layout.bannerIsland
            let inside = [
                CGPoint(x: body.midX, y: body.minY + 1),
                CGPoint(x: body.minX + 1, y: body.minY + 1),
                CGPoint(x: body.maxX - 1, y: body.midY),
                CGPoint(x: body.midX, y: body.midY),
            ]
            for point in inside {
                #expect(point.y < layout.notch.minY || !layout.hasNotch)
                let shown = layout.pointer(at: point, state: .collapsed, banner: true)
                #expect(shown.acceptsClicks, "\(screen.id) \(point)")
                #expect(shown.needsPolling)
                let gone = layout.pointer(at: point, state: .collapsed, banner: false)
                #expect(!gone.acceptsClicks)
                #expect(!gone.needsPolling)
            }
            var outside = [
                CGPoint(x: body.midX, y: body.minY - 1),
                CGPoint(x: body.minX - 1, y: body.midY),
                CGPoint(x: body.maxX + 1, y: body.midY),
            ]
            if layout.hasNotch {
                // Полоса под плечом рамки баннера прозрачна.
                outside.append(CGPoint(x: layout.bannerFrame.minX + 1, y: body.minY + 1))
            }
            for point in outside {
                let shown = layout.pointer(at: point, state: .collapsed, banner: true)
                #expect(!shown.acceptsClicks, "\(screen.id) \(point)")
                #expect(shown.needsPolling)
            }
        }
    }

    @Test func panelFrameContainsBanner() throws {
        var tall = notched()
        tall.safeAreaTop = 38
        for screen in [notched(), tall, notched(left: 700, right: 600), external()] {
            for wing: CGFloat in [40, 64, 200] {
                var layout = try #require(NotchGeometry.layout(for: [screen]))
                layout.wingWidth = wing
                #expect(layout.panelFrame.contains(layout.bannerIsland), "\(screen.id), крыло \(wing)")
                #expect(layout.panelFrame.contains(layout.bannerFrame), "\(screen.id), крыло \(wing)")
            }
        }
    }

    /// У выреза рамка формы баннера шире видимого тела на вогнутые плечи с каждой стороны,
    /// тело остается 400 pt, содержимое в 16 pt от его краев. У капсулы плеч нет.
    @Test func bannerFrameAddsShouldersAtNotchOnly() throws {
        let shoulder = NotchGeometry.bannerShoulderRadius
        #expect(shoulder == 9)
        var tall = notched()
        tall.safeAreaTop = 38
        for screen in [notched(), tall, notched(left: 700, right: 600)] {
            let layout = try #require(NotchGeometry.layout(for: [screen]))
            let body = layout.bannerIsland
            #expect(body.width == 400)
            #expect(layout.bannerFrame == body.insetBy(dx: -shoulder, dy: 0))
            let content = layout.bannerContent
            #expect(content.artwork.minX == 16)
            #expect(body.width - content.text.maxX == 16)
            #expect(body.width - content.waves.maxX == 16)
        }
        let pill = try #require(NotchGeometry.layout(for: [external()]))
        #expect(pill.bannerFrame == pill.bannerIsland)
    }

    /// Остров подавлен (пауза, блокировка, полноэкранное окно): баннер не расширяет зону
    /// наведения, кликов и опроса нет.
    @Test func suppressedIgnoresBannerZone() throws {
        for screen in [notched(), external()] {
            let layout = try #require(NotchGeometry.layout(for: [screen]))
            let text = onScreen(layout.bannerContent.text, in: layout.bannerIsland)
            let point = CGPoint(x: text.midX, y: text.midY)
            for state in [IslandState.hidden, .collapsed, .expanded] {
                let pointer = layout.pointer(at: point, state: state, suppressed: true, banner: true)
                #expect(pointer == layout.pointer(at: point, state: state, suppressed: true), "\(state)")
                #expect(!pointer.inHoverZone, "\(state)")
                #expect(!pointer.acceptsClicks, "\(state)")
                #expect(!pointer.needsPolling, "\(state)")
            }
        }
    }

    /// Баннер появился под неподвижным курсором: панель не раскрывается, пока курсор не
    /// сдвинется или не войдет в зону заново.
    @Test func bannerUnderStillPointerDoesNotCountAsHover() {
        #expect(!NotchPointer.countsAsHover(inZone: true, moved: false, banner: true, wasInZone: false))
        #expect(NotchPointer.countsAsHover(inZone: true, moved: true, banner: true, wasInZone: false))
        #expect(NotchPointer.countsAsHover(inZone: true, moved: false, banner: true, wasInZone: true))
        #expect(NotchPointer.countsAsHover(inZone: true, moved: false, banner: false, wasInZone: false))
        #expect(!NotchPointer.countsAsHover(inZone: false, moved: true, banner: true, wasInZone: true))
        #expect(!NotchPointer.countsAsHover(inZone: false, moved: false, banner: false, wasInZone: true))
    }

    /// Свайп над островом считается там, где остров виден сейчас: свернутый с крыльями,
    /// баннер или раскрытая панель. Скрытый и принудительно скрытый остров свайпов не ловит.
    @Test func swipeAreaFollowsIslandState() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let collapsed = layout.collapsedIsland(wingWidth: layout.wingWidth)
        #expect(layout.swipeArea(state: .hidden) == nil)
        #expect(layout.swipeArea(state: .hidden, banner: true) == nil)
        for state in [IslandState.collapsed, .expanded] {
            #expect(layout.swipeArea(state: state, suppressed: true) == nil, "\(state)")
            #expect(layout.swipeArea(state: state, suppressed: true, banner: true) == nil, "\(state)")
        }
        let cases: [(IslandState, Bool, CGRect)] = [
            (.collapsed, false, collapsed),
            (.collapsed, true, layout.bannerFrame),
            (.expanded, false, layout.expandedIsland),
            (.expanded, true, layout.expandedIsland),
        ]
        for (state, banner, island) in cases {
            let area = try #require(layout.swipeArea(state: state, banner: banner))
            #expect(area.minX == island.minX, "\(state) \(banner)")
            #expect(area.maxX == island.maxX, "\(state) \(banner)")
            #expect(area.minY == island.minY, "\(state) \(banner)")
            // Верхняя строка пикселей экрана тоже над островом.
            #expect(area.contains(CGPoint(x: island.midX, y: layout.screenFrame.maxY)), "\(state) \(banner)")
            #expect(!area.contains(CGPoint(x: island.midX, y: island.minY - 1)), "\(state) \(banner)")
        }
    }

    /// В отличие от зоны наведения, свайп над крыльями свернутого острова тоже считается.
    @Test func swipeAreaIncludesWings() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        #expect(layout.wingWidth > 0)
        let area = try #require(layout.swipeArea(state: .collapsed))
        let wing = CGPoint(x: layout.notch.minX - layout.wingWidth / 2, y: layout.notch.midY)
        #expect(area.contains(wing))
        #expect(!layout.hoverZone(expanded: false).contains(wing))
        let beyond = CGPoint(x: layout.notch.minX - layout.wingWidth - 1, y: layout.notch.midY)
        #expect(!area.contains(beyond))
    }

    /// Капсула висит под строкой меню: свайп над строкой меню над ней не считается.
    @Test func pillSwipeAreaStaysUnderMenuBar() throws {
        let layout = try #require(NotchGeometry.layout(for: [external()]))
        #expect(layout.swipeArea(state: .collapsed) == layout.collapsedIsland(wingWidth: layout.wingWidth))
        #expect(layout.swipeArea(state: .expanded) == layout.expandedIsland)
        #expect(layout.swipeArea(state: .collapsed, banner: true) == layout.bannerFrame)
        let menuBar = CGPoint(x: layout.notch.midX, y: layout.screenFrame.maxY - 1)
        for state in [IslandState.collapsed, .expanded] {
            for banner in [false, true] {
                let area = try #require(layout.swipeArea(state: state, banner: banner))
                #expect(!area.contains(menuBar), "\(state) \(banner)")
            }
        }
    }

    /// У выреза свайп считается из обоих мониторов: над вырезом окон приложений нет. У капсулы
    /// только из локального и только пока панель принимает мышь: иначе та же прокрутка листала
    /// бы и окно под капсулой.
    @Test func pillCountsOnlyLocalSwipesOverAcceptingPanel() throws {
        let notch = try #require(NotchGeometry.layout(for: [notched()]))
        let pill = try #require(NotchGeometry.layout(for: [external()]))
        for global in [false, true] {
            for accepts in [false, true] {
                #expect(notch.countsSwipe(global: global, panelAcceptsMouse: accepts), "\(global) \(accepts)")
            }
        }
        #expect(pill.countsSwipe(global: false, panelAcceptsMouse: true))
        #expect(!pill.countsSwipe(global: false, panelAcceptsMouse: false))
        #expect(!pill.countsSwipe(global: true, panelAcceptsMouse: true))
        #expect(!pill.countsSwipe(global: true, panelAcceptsMouse: false))
    }
}
