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
            guard Self.pid(from: windowInfo) == pid else {
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

    /// Returns a window's live WindowServer bounds in global screen coordinates, or nil if
    /// the window is unavailable or belongs to a different owner pid.
    static func frame(for cgWindowId: Int, ownerPid: pid_t? = nil) -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(cgWindowId)) as? [[String: Any]],
              let first = windowInfo.first else {
            return nil
        }

        if let ownerPid {
            guard let actualOwnerPid = pid(from: first),
                  actualOwnerPid == ownerPid else {
                return nil
            }
        }

        guard let boundsDict = first[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict) else {
            return nil
        }

        // CGWindow bounds are already in screen/global coordinates with y:0 at top-left.
        return rect
    }

    private static func pid(from windowInfo: [String: Any]) -> pid_t? {
        if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32 {
            return ownerPID
        }
        if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int {
            return pid_t(ownerPID)
        }
        if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? NSNumber {
            return ownerPID.int32Value
        }
        return nil
    }
}
