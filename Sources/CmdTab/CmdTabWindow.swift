/// Floating panel window for the CmdTab overlay

import AppKit

final class CmdTabWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false

        // Create container view for shadow (doesn't clip)
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        containerView.layer?.cornerRadius = 16

        // Add shadow to the container
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.3
        containerView.layer?.shadowRadius = 12
        containerView.layer?.shadowOffset = CGSize(width: 0, height: -4)

        // Create rounded rectangle visual effect view
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
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
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Position the window centered on the specified zone frame (in screen coordinates)
    func centerOnZone(frame zoneFrame: CGRect, screenDescriptor: ScreenDescriptor) {
        let cocoaFrame = screenDescriptor.screenToCocoa(zoneFrame)
        let visibleBounds = screenDescriptor.visibleCocoaBounds
        let windowSize = self.frame.size

        var x = (cocoaFrame.midX - windowSize.width / 2).rounded()
        var y = (cocoaFrame.midY - windowSize.height / 2).rounded()

        x = max(visibleBounds.minX, min(x, visibleBounds.maxX - windowSize.width))
        y = max(visibleBounds.minY, min(y, visibleBounds.maxY - windowSize.height))

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Position the window centered on the specified screen
    func centerOnScreen(_ screenId: CGDirectDisplayID, forFloatingZone: Bool = false) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == screenId
        }) else {
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

        let y: CGFloat
        if forFloatingZone {
            // Sit just above the floating-zone indicator at the screen bottom.
            y = (screenFrame.minY + 40).rounded()
        } else {
            y = (screenFrame.midY - windowSize.height / 2).rounded()
        }

        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
