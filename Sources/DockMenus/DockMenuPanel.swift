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
        ForceClickSuppression.apply(to: containerView)
        ForceClickSuppression.apply(to: visualEffectView)
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
