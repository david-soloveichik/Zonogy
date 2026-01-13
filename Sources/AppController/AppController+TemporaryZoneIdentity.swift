import Foundation
import AppKit
import ApplicationServices

// MARK: - Temporary zone protection helpers (wake and WinShot restoration)

extension AppController {
    internal func shouldProtectTemporaryZoneOccupant(windowId: Int) -> Bool {
        guard let deadline = temporaryZoneProtectionDeadlines[windowId] else {
            return false
        }
        if Date() < deadline {
            return true
        }
        temporaryZoneProtectionDeadlines.removeValue(forKey: windowId)
        return false
    }

    internal func scheduleTemporaryZoneProtection(windowId: Int) {
        // Record activity for the temp zone window before suppressing notifications.
        // This ensures the window being placed appears in AltTab recency order.
        recordActiveWindowForHistory(windowId: windowId, reason: "temporary-zone-protection")
        temporaryZoneProtectionDeadlines[windowId] = Date().addingTimeInterval(temporaryZoneProtectionDuration)
        Logger.debug("Temporary zone protection scheduled for window \(windowId) (duration: \(temporaryZoneProtectionDuration)s)")
        scheduleActivityRecordingSuppression(reason: "temporary-zone-protection")
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

    /// Suppress activity recording for the same duration as temporary zone protection.
    internal func scheduleActivityRecordingSuppression(reason: String) {
        let newDeadline = Date().addingTimeInterval(temporaryZoneProtectionDuration)
        if activityRecordingSuppressedUntil == nil || newDeadline > activityRecordingSuppressedUntil! {
            activityRecordingSuppressedUntil = newDeadline
            Logger.debug("Activity recording suppressed for \(temporaryZoneProtectionDuration)s (reason: \(reason))")
        }
    }

    internal func clearTemporaryZoneProtection(windowId: Int) {
        temporaryZoneProtectionDeadlines.removeValue(forKey: windowId)
    }

    /// Self-extends protection when triggered.
    internal func extendTemporaryZoneProtection(windowId: Int) {
        if temporaryZoneProtectionDeadlines[windowId] != nil {
            scheduleTemporaryZoneProtection(windowId: windowId)
        }
    }
}
