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
        temporaryZoneProtectionDeadlines[windowId] = Date().addingTimeInterval(temporaryZoneProtectionDuration)
        Logger.debug("Temporary zone protection scheduled for window \(windowId) (duration: \(temporaryZoneProtectionDuration)s)")
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
