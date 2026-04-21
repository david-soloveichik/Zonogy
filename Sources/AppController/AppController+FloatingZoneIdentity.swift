import Foundation
import AppKit
import ApplicationServices

// MARK: - Floating zone protection helpers (wake and WinShot restoration)

extension AppController {
    internal func shouldProtectFloatingZoneOccupant(windowId: Int) -> Bool {
        guard let deadline = floatingZoneProtectionDeadlines[windowId] else {
            return false
        }
        if Date() < deadline {
            return true
        }
        floatingZoneProtectionDeadlines.removeValue(forKey: windowId)
        return false
    }

    internal func scheduleFloatingZoneProtection(windowId: Int) {
        // Record activity for the floating zone window before suppressing notifications.
        // This ensures the window being placed appears in CmdTab recency order.
        recordActiveWindowForHistory(windowId: windowId, reason: "floating-zone-protection")
        floatingZoneProtectionDeadlines[windowId] = Date().addingTimeInterval(floatingZoneProtectionDuration)
        Logger.debug("Floating zone protection scheduled for window \(windowId) (duration: \(floatingZoneProtectionDuration)s)")
        scheduleActivityRecordingSuppression(reason: "floating-zone-protection")
        scheduleFloatingZoneProtectionExpiration(windowId: windowId)
    }

    /// Schedule a callback to reactivate the floating zone window when protection expires.
    private func scheduleFloatingZoneProtectionExpiration(windowId: Int) {
        // Cancel any existing expiration work item for this window.
        floatingZoneProtectionExpirationWorkItems[windowId]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.floatingZoneProtectionExpirationWorkItems.removeValue(forKey: windowId)

            // Check if the window is still in the floating zone.
            guard self.isWindowInFloatingZone(windowId),
                  let managed = self.windowController.window(withId: windowId) else {
                return
            }

            // Clear the deadline before activating to prevent a feedback loop.
            // (extendFloatingZoneProtection only extends if a deadline exists)
            self.floatingZoneProtectionDeadlines.removeValue(forKey: windowId)

            // Skip re-raise if the user has since minimized the window (avoids
            // spuriously unminimizing a floating window the user just dismissed).
            if managed.isMinimizedPerAccessibility {
                Logger.debug("Floating zone protection expired for window \(windowId); skipping raise (minimized)")
                return
            }

            // Use simple direct activation (no Zonogy-first workaround needed here).
            Logger.debug("Floating zone protection expired for window \(windowId); reactivating")
            self.raiseWindow(managed)
        }

        floatingZoneProtectionExpirationWorkItems[windowId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + floatingZoneProtectionDuration, execute: workItem)
    }

    // MARK: - Activity recording suppression (prevents twitchy history updates)

    /// Check if activity recording from notifications is currently suppressed.
    internal func isActivityRecordingSuppressed() -> Bool {
        guard let deadline = activityRecordingSuppressedUntil else {
            return false
        }
        if Date() < deadline {
            return true
        }
        activityRecordingSuppressedUntil = nil
        return false
    }

    /// Suppress activity recording for the same duration as floating zone protection.
    internal func scheduleActivityRecordingSuppression(reason: String) {
        cancelPendingWindowActivityRecord()
        let newDeadline = Date().addingTimeInterval(floatingZoneProtectionDuration)
        if activityRecordingSuppressedUntil == nil || newDeadline > activityRecordingSuppressedUntil! {
            activityRecordingSuppressedUntil = newDeadline
            Logger.debug("Activity recording suppressed for \(floatingZoneProtectionDuration)s (reason: \(reason))")
        }
    }

    internal func clearFloatingZoneProtection(windowId: Int) {
        floatingZoneProtectionDeadlines.removeValue(forKey: windowId)
        floatingZoneProtectionExpirationWorkItems[windowId]?.cancel()
        floatingZoneProtectionExpirationWorkItems.removeValue(forKey: windowId)
    }

    /// Self-extends protection when triggered.
    internal func extendFloatingZoneProtection(windowId: Int) {
        if floatingZoneProtectionDeadlines[windowId] != nil {
            scheduleFloatingZoneProtection(windowId: windowId)
        }
    }
}
