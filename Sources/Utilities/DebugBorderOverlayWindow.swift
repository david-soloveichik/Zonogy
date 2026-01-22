/// Reusable debug overlay window that draws a colored border.
import AppKit

/// A non-interactive overlay window that draws a colored border for debugging purposes.
/// Used by DockDebugBorderOverlayController and FullScreenDebugOverlayController.
final class DebugBorderOverlayWindow: NSPanel {
    private let borderView: BorderView

    /// Creates a debug border overlay window.
    /// - Parameters:
    ///   - borderColor: The color of the border.
    ///   - borderWidth: The width of the border in points.
    ///   - windowLevel: The window level for z-ordering.
    init(borderColor: NSColor, borderWidth: CGFloat, windowLevel: NSWindow.Level) {
        borderView = BorderView(borderColor: borderColor, borderWidth: borderWidth)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = true
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        level = windowLevel
        collectionBehavior = [
            .canJoinAllSpaces,
            .ignoresCycle,
            .transient
        ]
        contentView = borderView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFront(sender)
    }
}

private final class BorderView: NSView {
    init(borderColor: NSColor, borderWidth: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = borderWidth
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
