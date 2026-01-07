/// Floating panel window for the AltTab overlay

import AppKit

final class AltTabWindow: NSPanel {
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = true
        isMovableByWindowBackground = true

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

        var x = cocoaFrame.midX - windowSize.width / 2
        var y = cocoaFrame.midY - windowSize.height / 2

        x = max(visibleBounds.minX, min(x, visibleBounds.maxX - windowSize.width))
        y = max(visibleBounds.minY, min(y, visibleBounds.maxY - windowSize.height))

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Position the window centered on the specified screen
    func centerOnScreen(_ screenId: CGDirectDisplayID, forTemporaryZone: Bool = false) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == screenId
        }) else {
            if let mainScreen = NSScreen.main {
                center(on: mainScreen, forTemporaryZone: forTemporaryZone)
            }
            return
        }

        center(on: screen, forTemporaryZone: forTemporaryZone)
    }

    private func center(on screen: NSScreen, forTemporaryZone: Bool = false) {
        let screenFrame = screen.visibleFrame
        let windowSize = frame.size
        let x = screenFrame.midX - windowSize.width / 2

        let y: CGFloat
        if forTemporaryZone {
            y = screenFrame.minY + screenFrame.height * 0.33 - windowSize.height / 2
        } else {
            y = screenFrame.midY - windowSize.height / 2
        }

        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
