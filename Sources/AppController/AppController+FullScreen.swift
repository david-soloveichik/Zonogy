/// Full-screen mode tracking integration.
import AppKit

extension AppController {
    // MARK: - FullScreenTrackerDelegate
    func fullScreenTracker(_ tracker: FullScreenTracker, didChangeFullScreenStateFor displayId: CGDirectDisplayID) {
        updateFullScreenDebugOverlay(for: displayId)
    }

    func fullScreenTracker(_ tracker: FullScreenTracker, didStartTrackingFullScreenWindow info: FullScreenWindowInfo) {
        // Subscribe to destroyed notification for this full-screen window
        windowController.registerDestroyedNotification(for: info.element, pid: info.pid)
    }

    func fullScreenTracker(_ tracker: FullScreenTracker, didStopTrackingFullScreenWindow info: FullScreenWindowInfo) {
        // Unsubscribe from destroyed notification for this full-screen window
        windowController.removeDestroyedNotification(for: info.element, pid: info.pid)
    }

    /// Update the debug overlay for a specific display based on full-screen state.
    internal func updateFullScreenDebugOverlay(for displayId: CGDirectDisplayID) {
        guard let overlay = fullScreenDebugOverlay else { return }

        if fullScreenTracker.isFullScreen(displayId: displayId) {
            // Show orange frame around the screen
            guard let context = screenContexts[displayId] else {
                overlay.hideOverlay(for: displayId)
                return
            }

            // Convert screen bounds to accessibility coordinates for the overlay
            let cocoaBounds = context.descriptor.cocoaBounds
            let accessibilityBounds = CoordinateConversion.cocoaToAccessibility(
                cocoaFrame: cocoaBounds,
                primaryScreenBounds: primaryScreenBounds
            )
            overlay.setScreenFrame(displayId: displayId, screenFrame: accessibilityBounds)
        } else {
            overlay.hideOverlay(for: displayId)
        }
    }

    /// Update debug overlays for all screens.
    internal func updateAllFullScreenDebugOverlays() {
        guard fullScreenDebugOverlay != nil else { return }
        for displayId in screenContexts.keys {
            updateFullScreenDebugOverlay(for: displayId)
        }
    }

    /// Refresh full-screen tracking for all screens.
    /// Call this after display configuration changes or window captures.
    internal func refreshFullScreenTracking() {
        fullScreenTracker.updateAllScreens(screenContexts: screenContexts)
        // Update all overlays to ensure positions are correct even if state didn't change
        // (e.g., screen bounds changed but full-screen state is the same)
        updateAllFullScreenDebugOverlays()
    }

    /// Notify full-screen tracker that an application terminated.
    internal func notifyFullScreenTrackerOfAppTermination(pid: pid_t) {
        fullScreenTracker.applicationDidTerminate(pid: pid)
    }

    /// Notify full-screen tracker that a specific window closed.
    /// This is a direct lookup - use when you know the exact window that closed.
    internal func notifyFullScreenTrackerOfWindowClose(cgWindowId: CGWindowID) {
        fullScreenTracker.windowDidClose(cgWindowId: cgWindowId)
    }

    /// Check if a specific non-movable window is a full-screen window.
    /// Called when capture rejects a window due to non-movability.
    internal func checkNonMovableWindowForFullScreen(element: AXUIElement, pid: pid_t, cgWindowId: CGWindowID, frame: CGRect) {
        fullScreenTracker.checkNonMovableWindow(element: element, pid: pid, cgWindowId: cgWindowId, frame: frame, screenContexts: screenContexts)
    }
}
