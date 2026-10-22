import AppKit
import Testing
@testable import WaveFeels

@MainActor
struct NotchPanelTests {
    @Test func panelPassesClicksAndStaysAboveMenuBar() {
        _ = NSApplication.shared
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 210))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(!panel.styleMask.contains(.titled))
        #expect(panel.level.rawValue == NSWindow.Level.mainMenu.rawValue + 3)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isOpaque)
        #expect(!panel.hasShadow)
        #expect(panel.collectionBehavior.contains([.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]))
        #expect(panel.frame == NSRect(x: 0, y: 0, width: 480, height: 210))
        panel.close()
    }
}
