/// Floating panel window for the Launcher overlay

import AppKit

final class LauncherWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 400),
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = true
        isMovableByWindowBackground = true

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
        // Convert zone frame from screen coordinates to Cocoa coordinates
        let cocoaFrame = screenDescriptor.screenToCocoa(zoneFrame)

        let windowSize = self.frame.size
        let x = cocoaFrame.midX - windowSize.width / 2
        let y = cocoaFrame.midY - windowSize.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Position the window centered on the specified screen
    func centerOnScreen(_ screenId: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == screenId
        }) else {
            // Fall back to main screen
            if let mainScreen = NSScreen.main {
                center(on: mainScreen)
            }
            return
        }

        center(on: screen)
    }

    private func center(on screen: NSScreen) {
        let screenFrame = screen.visibleFrame
        let windowSize = frame.size
        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.midY - windowSize.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
