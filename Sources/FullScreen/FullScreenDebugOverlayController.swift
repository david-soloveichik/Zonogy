/// Draws orange debug borders around screens in full-screen mode.
import AppKit

/// Set to true to show orange debug borders around full-screen screens.
let kShowDebugFullScreenOverlay = true

/// Manages debug overlay windows that show orange borders around screens in full-screen mode.
final class FullScreenDebugOverlayController {
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
            // Place above most windows but below the dock debug overlay
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 100)
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
            layer?.borderColor = NSColor.systemOrange.cgColor
            layer?.borderWidth = 4.0
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private let primaryScreenBounds: CGRect
    private var overlayWindows: [CGDirectDisplayID: OverlayWindow] = [:]

    init(primaryScreenBounds: CGRect) {
        self.primaryScreenBounds = primaryScreenBounds
    }

    /// Update the overlay for a specific display.
    /// Pass nil for screenFrame to hide the overlay.
    func setScreenFrame(displayId: CGDirectDisplayID, screenFrame: CGRect?) {
        if let screenFrame {
            let window = overlayWindows[displayId] ?? createOverlayWindow(for: displayId)
            overlayWindows[displayId] = window

            let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: screenFrame,
                primaryScreenBounds: primaryScreenBounds
            ).integral

            window.setFrame(cocoaFrame, display: true)
            window.orderFrontRegardless()
            Logger.debug("FullScreenDebugOverlay: showing orange frame on screen \(ScreenContextStore.loggingIndex(for: displayId))")
        } else {
            hideOverlay(for: displayId)
        }
    }

    /// Hide the overlay for a specific display.
    func hideOverlay(for displayId: CGDirectDisplayID) {
        if let window = overlayWindows.removeValue(forKey: displayId) {
            window.orderOut(nil)
            Logger.debug("FullScreenDebugOverlay: hiding orange frame on screen \(ScreenContextStore.loggingIndex(for: displayId))")
        }
    }

    /// Hide all overlays.
    func hideAll() {
        for (displayId, window) in overlayWindows {
            window.orderOut(nil)
            Logger.debug("FullScreenDebugOverlay: hiding orange frame on screen \(ScreenContextStore.loggingIndex(for: displayId))")
        }
        overlayWindows.removeAll()
    }

    private func createOverlayWindow(for displayId: CGDirectDisplayID) -> OverlayWindow {
        let window = OverlayWindow()
        window.contentView = BorderView(frame: .zero)
        return window
    }
}
