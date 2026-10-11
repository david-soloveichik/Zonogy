/// Draws green debug borders around the notifications Notification Center shows.
import AppKit

/// Outlines each notification that `NotificationCenterMonitor` detects, while the Debug toggle is on.
final class NotificationDebugOverlayController {
    /// Notification Center's notification window sits one level above the Dock; the borders go above it.
    private static let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)

    private var primaryScreenBounds: CGRect
    /// One border per shown notification, reused as notifications come and go.
    private var overlayWindows: [DebugBorderOverlayWindow] = []

    init(primaryScreenBounds: CGRect) {
        self.primaryScreenBounds = primaryScreenBounds
    }

    func updatePrimaryScreenBounds(_ bounds: CGRect) {
        primaryScreenBounds = bounds
    }

    /// Shows one border per frame (accessibility coordinates) and hides the rest.
    func showBorders(around accessibilityFrames: [CGRect]) {
        while overlayWindows.count < accessibilityFrames.count {
            overlayWindows.append(DebugBorderOverlayWindow(borderColor: .systemGreen, borderWidth: 3.0, windowLevel: Self.windowLevel))
        }
        for (index, window) in overlayWindows.enumerated() {
            guard index < accessibilityFrames.count else {
                window.orderOut(nil)
                continue
            }
            let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: accessibilityFrames[index],
                primaryScreenBounds: primaryScreenBounds
            ).integral
            window.setFrame(cocoaFrame, display: true)
            window.orderFrontRegardless()
        }
    }
}
