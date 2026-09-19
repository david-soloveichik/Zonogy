/// Centers a frosted panel on a zone or on a display, within the display's visible area.

import AppKit

extension FrostedPanel {
    /// Centers the panel on a zone frame (screen coordinates, origin at the top left), clamped to the
    /// zone's display so a small zone still leaves the panel fully visible.
    func centerOnZone(frame zoneFrame: CGRect, screenDescriptor: ScreenDescriptor) {
        let cocoaFrame = screenDescriptor.screenToCocoa(zoneFrame)
        let visibleBounds = screenDescriptor.visibleCocoaBounds
        var x = (cocoaFrame.midX - frame.width / 2).rounded()
        var y = (cocoaFrame.midY - frame.height / 2).rounded()
        x = max(visibleBounds.minX, min(x, visibleBounds.maxX - frame.width))
        y = max(visibleBounds.minY, min(y, visibleBounds.maxY - frame.height))
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Centers the panel on the display `screenId`, or on the main display when that one is gone.
    /// For the floating zone, which has no placeholder to center on, the panel instead sits just
    /// above the floating zone indicator at the bottom of the display.
    func centerOnScreen(_ screenId: CGDirectDisplayID, forFloatingZone: Bool = false) {
        guard let screen = NSScreen.screens.first(where: { ScreenContextStore.displayId(for: $0) == screenId }) ?? NSScreen.main else {
            return
        }
        let bounds = screen.visibleFrame
        let x = (bounds.midX - frame.width / 2).rounded()
        let y = forFloatingZone ? (bounds.minY + 40).rounded() : (bounds.midY - frame.height / 2).rounded()
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
