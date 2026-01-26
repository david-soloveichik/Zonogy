/// Draws orange debug borders around screens in full-screen mode.
import AppKit

/// Set to true to show orange debug borders around full-screen screens.
let kShowDebugFullScreenOverlay = true

/// Manages debug overlay windows that show orange borders around screens in full-screen mode.
final class FullScreenDebugOverlayController {
    private static let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 100)

    private let primaryScreenBounds: CGRect
    private var overlayWindows: [CGDirectDisplayID: DebugBorderOverlayWindow] = [:]

    init(primaryScreenBounds: CGRect) {
        self.primaryScreenBounds = primaryScreenBounds
    }

    /// Update the overlay for a specific display.
    /// Pass nil for screenFrame to hide the overlay.
    func setScreenFrame(displayId: CGDirectDisplayID, screenFrame: CGRect?) {
        if let screenFrame {
            let window = overlayWindows[displayId] ?? createOverlayWindow()
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

    private func createOverlayWindow() -> DebugBorderOverlayWindow {
        DebugBorderOverlayWindow(
            borderColor: .systemOrange,
            borderWidth: 4.0,
            windowLevel: Self.windowLevel
        )
    }
}
