import AppKit

/// Панель у выреза: без рамки, не активирует приложение, стоит над строкой меню на всех
/// пространствах, в том числе полноэкранных. По умолчанию пропускает все клики; принимать их
/// разрешает только `NotchWindowController` над раскрытым островом и над баннером нового трека.
final class NotchPanel: NSPanel {
    /// Нажатие левой кнопкой в панели, до того как его разберет содержимое.
    var onLeftMouseDown: (@MainActor () -> Void)?

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
        // Приложение почти всегда неактивно, когда курсор над островом: без этого
        // подсказка «Открыть <имя>» у кнопки источника не появится.
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onLeftMouseDown?()
        }
        super.sendEvent(event)
    }

    /// Панель частично лежит на строке меню; AppKit не должен сдвигать ее под строку меню.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
