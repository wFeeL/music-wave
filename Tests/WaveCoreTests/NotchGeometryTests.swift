import Testing
import Foundation
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
        let wingPoint = CGPoint(x: layout.notch.minX - 10, y: layout.notch.midY)
        #expect(!layout.hoverZone(expanded: false).contains(wingPoint))
        #expect(layout.hoverZone(expanded: false).contains(CGPoint(x: layout.notch.midX, y: layout.notch.midY)))
        #expect(layout.hoverZone(expanded: true) == layout.expandedIsland)
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
        #expect(hover.maxY == screen.frame.maxY)
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
}
