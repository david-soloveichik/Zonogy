/// Full-screen mode tracking integration.
import AppKit

extension AppController {
    // MARK: - FullScreenTrackerDelegate
    func fullScreenTracker(_ tracker: FullScreenTracker, didChangeFullScreenStateFor displayId: CGDirectDisplayID) {
        updateFullScreenDebugOverlay(for: displayId)
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

    /// Notify full-screen tracker that an application terminated.
    internal func notifyFullScreenTrackerOfAppTermination(pid: pid_t) {
        fullScreenTracker.applicationDidTerminate(pid: pid)
    }

    /// Notify full-screen tracker that a specific window closed.
    internal func notifyFullScreenTrackerOfWindowClose(windowId: Int) {
        fullScreenTracker.windowDidClose(windowId: windowId)
    }

    /// Check full-screen state for a window after resize.
    /// Called when kAXResizedNotification is received for a managed window.
    internal func checkWindowFullScreenState(windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            return
        }

        let screenDisplayId = managed.screenDisplayId ?? detectScreenId(for: managed) ?? primaryScreenId
        let bundleId = NSRunningApplication(processIdentifier: managed.backing.pid)?.bundleIdentifier

        fullScreenTracker.handleWindowFullScreenStateChange(
            windowId: windowId,
            cgWindowId: CGWindowID(managed.backing.cgWindowId),
            element: managed.backing.element,
            pid: managed.backing.pid,
            bundleIdentifier: bundleId,
            screenDisplayId: screenDisplayId
        )
    }

    /// Scan all managed windows for their full-screen state.
    /// Called at startup and after display reconfiguration to detect windows
    /// that are already in full-screen mode.
    internal func scanAllWindowsForFullScreenState() {
        for managed in windowController.allWindows {
            // Skip minimized windows - they can't be in full-screen
            if managed.isMinimizedPerAccessibility {
                continue
            }
            checkWindowFullScreenState(windowId: managed.windowId)
        }
        updateAllFullScreenDebugOverlays()
    }
}
