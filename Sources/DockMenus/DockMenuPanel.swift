/// Compact floating panel for DockMenu hover display.

import AppKit

/// A non-activating floating panel for displaying the DockMenu.
final class DockMenuPanel: FrostedPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300), cornerRadius: 12)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        if let contentView {
            ForceClickSuppression.apply(to: contentView)
        }
        ForceClickSuppression.apply(to: visualEffectView)
    }

    override var canBecomeKey: Bool {
        false  // Never become key - don't steal focus
    }

    /// Position the panel adjacent to the Dock item. All frames are in Cocoa coordinates.
    /// - Parameters:
    ///   - itemFrame: Frame of the hovered Dock item.
    ///   - dockFrame: The Dock's revealed frame (stable throughout the autohide slide).
    ///   - edge: The display edge the Dock sits on.
    ///   - screenBounds: The visible bounds of the Dock's display.
    ///   - hasWindows: Whether the app has any windows (affects vertical alignment).
    func positionAdjacentTo(
        itemFrame: CGRect,
        dockFrame: CGRect,
        edge: DockLocation.Edge,
        screenBounds: NSRect,
        hasWindows: Bool
    ) {
        let panelSize = frame.size
        let gap: CGFloat = 8

        var x: CGFloat
        var y: CGFloat

        switch edge {
        case .bottom:
            // Panel above the Dock, horizontally centered on the hovered item
            x = itemFrame.midX - panelSize.width / 2
            y = dockFrame.maxY + gap

        case .left, .right:
            // Panel to the inside of the display, beside the Dock
            x = edge == .left ? dockFrame.maxX + gap : dockFrame.minX - panelSize.width - gap
            // Position so target row aligns with Dock icon center.
            let targetOffsetFromTop: CGFloat
            if hasWindows {
                // First window row: top padding (6) + header (40) + scroll padding (2) + half row (16) = 64pt
                targetOffsetFromTop = 64
            } else {
                // App header center: top padding (6) + half header (20) = 26pt
                targetOffsetFromTop = 26
            }
            y = itemFrame.midY - panelSize.height + targetOffsetFromTop
        }

        // Clamp to screen bounds
        x = max(screenBounds.minX, min(x, screenBounds.maxX - panelSize.width))
        y = max(screenBounds.minY, min(y, screenBounds.maxY - panelSize.height))

        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
