import Foundation
import ApplicationServices

/// Lightweight helpers for querying the WindowServer via `CGWindowListCopyWindowInfo`.
enum WindowServerWindowList {
    /// Returns on-screen CG window numbers ordered front-to-back, or nil if the list cannot be read.
    static func onScreenWindowNumbersFrontToBack() -> [Int]? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var windowNumbers: [Int] = []
        windowNumbers.reserveCapacity(windowList.count)
        for windowInfo in windowList {
            if let windowNumber = windowInfo[kCGWindowNumber as String] as? Int {
                windowNumbers.append(windowNumber)
                continue
            }
            if let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber {
                windowNumbers.append(windowNumber.intValue)
                continue
            }
        }

        return windowNumbers
    }

    /// Returns true when a window with the given owner pid and CG window number is
    /// currently known to the WindowServer. Uses the same option set as the
    /// destroyed-window prune (`pruneDestroyedExternalWindows`) so both code paths
    /// agree on whether a window still exists.
    static func containsWindow(pid: pid_t, cgWindowId: Int) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid else {
                continue
            }
            if let number = windowInfo[kCGWindowNumber as String] as? Int, number == cgWindowId {
                return true
            }
            if let number = windowInfo[kCGWindowNumber as String] as? NSNumber, number.intValue == cgWindowId {
                return true
            }
        }

        return false
    }
}

