/// Floating panel window for the Launcher overlay

import AppKit

final class LauncherWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // Disable window shadow - we'll add custom shadow
        level = .popUpMenu  // Higher than .floating to appear above zone overlays
        collectionBehavior = [.transient, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false

        // Create container view for shadow (doesn't clip)
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        containerView.layer?.cornerRadius = 16

        // Add shadow to the container (so it's not clipped)
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.3
        containerView.layer?.shadowRadius = 12
        containerView.layer?.shadowOffset = CGSize(width: 0, height: -4)

        // Create rounded rectangle visual effect view for elegant appearance
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.masksToBounds = true  // Clip content to rounded corners

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
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Position the window centered on the specified zone frame (in screen coordinates)
    /// The zone frame uses screen coordinates (y:0 at top-left), so we convert to Cocoa coordinates
    func centerOnZone(frame zoneFrame: CGRect, screenDescriptor: ScreenDescriptor) {
        let cocoaFrame = screenDescriptor.screenToCocoa(zoneFrame)
        let visibleBounds = screenDescriptor.visibleCocoaBounds
        let windowSize = self.frame.size

        // Calculate centered position
        var x = (cocoaFrame.midX - windowSize.width / 2).rounded()
        var y = (cocoaFrame.midY - windowSize.height / 2).rounded()

        // Clamp to keep window within visible screen bounds
        x = max(visibleBounds.minX, min(x, visibleBounds.maxX - windowSize.width))
        y = max(visibleBounds.minY, min(y, visibleBounds.maxY - windowSize.height))

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Position the window centered on the specified screen
    /// - Parameters:
    ///   - screenId: The display ID of the screen
    ///   - forFloatingZone: If true, position lower on the screen (closer to the floating zone indicator)
    func centerOnScreen(_ screenId: CGDirectDisplayID, forFloatingZone: Bool = false) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == screenId
        }) else {
            // Fall back to main screen
            if let mainScreen = NSScreen.main {
                center(on: mainScreen, forFloatingZone: forFloatingZone)
            }
            return
        }

        center(on: screen, forFloatingZone: forFloatingZone)
    }

    private func center(on screen: NSScreen, forFloatingZone: Bool = false) {
        let screenFrame = screen.visibleFrame
        let windowSize = frame.size
        let x = (screenFrame.midX - windowSize.width / 2).rounded()

        // For floating zone, position lower on screen (closer to the bottom indicator)
        // Use about 1/3 from bottom instead of centered
        let y: CGFloat
        if forFloatingZone {
            y = (screenFrame.minY + screenFrame.height * 0.33 - windowSize.height / 2).rounded()
        } else {
            y = (screenFrame.midY - windowSize.height / 2).rounded()
        }

        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
