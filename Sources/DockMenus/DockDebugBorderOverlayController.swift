/// Draws a blue debug border around the Dock's AXList frame.
import AppKit

final class DockDebugBorderOverlayController {
    private var primaryScreenBounds: CGRect
    private let window: DebugBorderOverlayWindow

    init(primaryScreenBounds: CGRect) {
        self.primaryScreenBounds = primaryScreenBounds
        self.window = DebugBorderOverlayWindow(
            borderColor: .systemBlue,
            borderWidth: 3.0,
            windowLevel: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        )
    }

    func updatePrimaryScreenBounds(_ bounds: CGRect) {
        primaryScreenBounds = bounds
    }

    func setListFrame(accessibilityFrame: CGRect?) {
        guard let accessibilityFrame else {
            Logger.debug("DockDebugBorderOverlayController: hiding blue frame because accessibilityFrame is invalid")
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
