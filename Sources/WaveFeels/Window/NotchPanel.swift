import AppKit

/// Панель у выреза: без рамки, не активирует приложение, стоит над строкой меню на всех
/// пространствах, в том числе полноэкранных. По умолчанию пропускает все клики; принимать их
/// разрешает только `NotchWindowController` над раскрытым островом.
final class NotchPanel: NSPanel {
    /// `.nonactivatingPanel` задается только здесь: смена флага после создания окна
    /// не перестраивает его в WindowServer.
    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        // Ключевой панель становится только для элементов, которым это нужно; кнопки
        // срабатывают с первого клика, приложение при этом не активируется.
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    /// Панель частично лежит на строке меню; AppKit не должен сдвигать ее под строку меню.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
