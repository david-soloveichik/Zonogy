/// Full-screen application detection
import AppKit

extension AppController {
    /// Returns the set of display IDs that are considered to have a full-screen application.
    ///
    /// A screen has a full-screen app if any non-system window spans its entire width.
    /// Finder, Window Server, and Dock are excluded from the check.
    ///
    /// - Returns: Set of CGDirectDisplayID values for screens with full-screen apps.
    func screensWithFullScreenApp() -> Set<CGDirectDisplayID> {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        // Build a map of screen bounds in CG coordinates for width comparison
        var screenBoundsMap: [CGDirectDisplayID: CGRect] = [:]
        for (screenId, context) in screenContexts {
            let cocoaBounds = context.descriptor.cocoaBounds
            let cgBounds = CoordinateConversion.cocoaToAccessibility(
                cocoaFrame: cocoaBounds,
                primaryScreenBounds: primaryScreenBounds
            )
            screenBoundsMap[screenId] = cgBounds
        }

        var result: Set<CGDirectDisplayID> = []

        for windowInfo in windowInfoList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: boundsDict),
                  cgFrame.width > 0 && cgFrame.height > 0 else {
                continue
            }

            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String
            let isSystemWindow = ownerName == "Finder" || ownerName == "Window Server" || ownerName == "Dock"
            if isSystemWindow { continue }

            for (screenId, screenBounds) in screenBoundsMap {
                if result.contains(screenId) { continue }

                let spansFullWidth = cgFrame.minX <= screenBounds.minX &&
                                     cgFrame.maxX >= screenBounds.maxX
                let isOnScreen = cgFrame.intersects(screenBounds)

                if spansFullWidth && isOnScreen {
                    let screenIndex = screenContextStore.loggingIndex(for: screenId)
                    Logger.debug("FullScreenDetection: Full-width window on screen \(screenIndex): owner='\(ownerName ?? "nil")'")
                    result.insert(screenId)
                }
            }

            // Early exit if all screens have full-screen apps
            if result.count == screenBoundsMap.count {
                return result
            }
        }

        return result
    }

    /// Check if a specific screen has a full-screen application.
    func hasFullScreenApp(on screenId: CGDirectDisplayID) -> Bool {
        screensWithFullScreenApp().contains(screenId)
    }
}
