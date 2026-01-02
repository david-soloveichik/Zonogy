import AppKit

/// Draws a red border around the currently detected Dock frame to validate Dock geometry tracking.
final class DockDebugBorderOverlayController {
    private final class OverlayWindow: NSPanel {
        init() {
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
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
            collectionBehavior = [
                .canJoinAllSpaces,
                .ignoresCycle,
                .transient
            ]
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            orderFront(sender)
        }
    }

    private final class BorderView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.systemRed.cgColor
            layer?.borderWidth = 3.0
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private let primaryScreenBounds: CGRect
    private let window = OverlayWindow()

    init(primaryScreenBounds: CGRect) {
        self.primaryScreenBounds = primaryScreenBounds
        window.contentView = BorderView(frame: .zero)
    }

    func setDockFrame(accessibilityFrame: CGRect?, isVisible: Bool) {
        guard let accessibilityFrame, isVisible else {
            window.orderOut(nil)
            return
        }

        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: accessibilityFrame,
            primaryScreenBounds: primaryScreenBounds
        ).integral

        window.setFrame(cocoaFrame, display: true)
        window.orderFrontRegardless()
    }
}

