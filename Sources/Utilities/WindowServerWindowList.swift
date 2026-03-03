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
}

