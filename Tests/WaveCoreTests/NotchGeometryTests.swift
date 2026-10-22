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
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let panel = layout.panelFrame
        #expect(panel.contains(layout.expandedIsland))
        #expect(panel.contains(layout.collapsedIsland(wingWidth: NotchGeometry.maxWingWidth)))
        #expect(panel.minY == layout.expandedIsland.minY - 40)
        #expect(panel.maxY == 956)
        // Запас по бокам под тень и «вздох».
        #expect(panel.minX == layout.expandedIsland.minX - NotchGeometry.panelSideMargin)
        #expect(panel.maxX == layout.expandedIsland.maxX + NotchGeometry.panelSideMargin)
        #expect(NotchGeometry.panelSideMargin == 24)
        // Клики только над самим раскрытым островом, не над запасом.
        let margin = CGPoint(x: panel.minX + 4, y: layout.expandedIsland.midY)
        #expect(!layout.pointer(at: margin, state: .expanded).acceptsClicks)
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
}
