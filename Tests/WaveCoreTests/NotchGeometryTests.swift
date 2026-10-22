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
        #expect(island.width == 480)
        #expect(island.height == 170)
        #expect(island.midX == layout.notch.midX)
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
        #expect(layout.notch.maxY == screen.frame.maxY - 24 - 6)
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

    @Test func pointerOverNotchStartsPolling() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let pointer = layout.pointer(at: CGPoint(x: layout.notch.midX, y: 956), state: .collapsed)
        #expect(pointer == NotchPointer(inHoverZone: true, acceptsClicks: false, needsPolling: true))
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

    @Test func expandedAcceptsClicksOnlyInsideIsland() throws {
        let layout = try #require(NotchGeometry.layout(for: [notched()]))
        let island = layout.expandedIsland
        let inside = layout.pointer(at: CGPoint(x: island.minX + 5, y: island.minY + 5), state: .expanded)
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
        let belowMenuBar = CGRect(x: 0, y: 0, width: 1470, height: 914)
        for window in [zoomedAboveDock, narrower, otherScreen, belowMenuBar] {
            #expect(!NotchGeometry.windowCoversScreen(window, screen: screen, topAllowance: 32))
        }
    }
}
