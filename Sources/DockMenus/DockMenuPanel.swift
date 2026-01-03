/// Compact floating panel for DockMenu hover display.

import AppKit

/// A non-activating floating panel for displaying the DockMenu.
final class DockMenuPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // Custom shadow via container view
        level = .popUpMenu  // Above zone overlays and Dock
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        isMovableByWindowBackground = false

        // Create container view for shadow (doesn't clip)
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        containerView.layer?.cornerRadius = 12

        // Add shadow to the container
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.25
        containerView.layer?.shadowRadius = 10
        containerView.layer?.shadowOffset = CGSize(width: 0, height: -3)

        // Create rounded visual effect view
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 12
        visualEffectView.layer?.masksToBounds = true

        // Add visual effect view to container
        containerView.addSubview(visualEffectView)
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: containerView.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        contentView = containerView
    }

    var visualEffectView: NSVisualEffectView? {
        contentView?.subviews.first as? NSVisualEffectView
    }

    override var canBecomeKey: Bool {
        false  // Never become key - don't steal focus
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Position the panel adjacent to the Dock item.
    /// - Parameters:
    ///   - itemFrame: Accessibility frame of the Dock item (screen coordinates, y:0 at top).
    ///   - dockFrame: Stable Dock frame (where the Dock is when fully visible, screen coordinates).
    ///   - orientation: Dock orientation (horizontal for bottom, vertical for left/right).
    ///   - screenBounds: The visible screen bounds in Cocoa coordinates.
    ///   - hasWindows: Whether the app has any windows (affects vertical alignment).
    func positionAdjacentTo(
        itemFrame: CGRect,
        dockFrame: CGRect,
        orientation: DockOrientation,
        screenBounds: NSRect,
        hasWindows: Bool
    ) {
        let panelSize = frame.size
        let gap: CGFloat = 8

        // Convert frames from screen coordinates (y:0 at top) to Cocoa (y:0 at bottom)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenBounds.height
        let cocoaItemFrame = CGRect(
            x: itemFrame.origin.x,
            y: primaryHeight - itemFrame.origin.y - itemFrame.height,
            width: itemFrame.width,
            height: itemFrame.height
        )
        let cocoaDockFrame = CGRect(
            x: dockFrame.origin.x,
            y: primaryHeight - dockFrame.origin.y - dockFrame.height,
            width: dockFrame.width,
            height: dockFrame.height
        )

        var x: CGFloat
        var y: CGFloat

        switch orientation {
        case .horizontal:
            // Dock on bottom: panel above Dock, horizontally centered on item
            // x: from itemFrame (center on hovered item)
            // y: from dockFrame (stable Dock top edge, handles autohide animation)
            x = cocoaItemFrame.midX - panelSize.width / 2
            y = cocoaDockFrame.maxY + gap

        case .vertical:
            // Dock on left or right: panel to inside of screen
            // x: from dockFrame (stable Dock edge, handles autohide animation)
            // y: from itemFrame (align with hovered item)
            let isOnLeft = cocoaDockFrame.midX < screenBounds.midX
            if isOnLeft {
                // Dock on left: panel to right of Dock
                x = cocoaDockFrame.maxX + gap
            } else {
                // Dock on right: panel to left of Dock
                x = cocoaDockFrame.minX - panelSize.width - gap
            }
            // Position so target row aligns with Dock icon center.
            let targetOffsetFromTop: CGFloat
            if hasWindows {
                // First window row: top padding (6) + header (40) + scroll padding (2) + half row (16) = 64pt
                targetOffsetFromTop = 64
            } else {
                // App header center: top padding (6) + half header (20) = 26pt
                targetOffsetFromTop = 26
            }
            y = cocoaItemFrame.midY - panelSize.height + targetOffsetFromTop
        }

        // Clamp to screen bounds
        x = max(screenBounds.minX, min(x, screenBounds.maxX - panelSize.width))
        y = max(screenBounds.minY, min(y, screenBounds.maxY - panelSize.height))

        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
