import AppKit

/// Draws debug borders around Dock frames: red for the Dock window frame, blue for the AXList frame.
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
        init(frame frameRect: NSRect, borderColor: NSColor) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = borderColor.cgColor
            layer?.borderWidth = 3.0
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private let primaryScreenBounds: CGRect
    private let dockWindow = OverlayWindow()
    private let listWindow = OverlayWindow()

    init(primaryScreenBounds: CGRect) {
        self.primaryScreenBounds = primaryScreenBounds
        dockWindow.contentView = BorderView(frame: .zero, borderColor: .systemRed)
        listWindow.contentView = BorderView(frame: .zero, borderColor: .systemBlue)
    }

    func setDockFrame(accessibilityFrame: CGRect?, isVisible: Bool) {
        guard let accessibilityFrame, isVisible else {
            dockWindow.orderOut(nil)
            return
        }

        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: accessibilityFrame,
            primaryScreenBounds: primaryScreenBounds
        ).integral

        dockWindow.setFrame(cocoaFrame, display: true)
        dockWindow.orderFrontRegardless()
    }

    func setListFrame(accessibilityFrame: CGRect?) {
        guard let accessibilityFrame else {
            listWindow.orderOut(nil)
            return
        }

        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: accessibilityFrame,
            primaryScreenBounds: primaryScreenBounds
        ).integral

        listWindow.setFrame(cocoaFrame, display: true)
        listWindow.orderFrontRegardless()
    }
}

