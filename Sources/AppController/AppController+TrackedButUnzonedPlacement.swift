import Foundation
import AppKit

/// Shared placement helpers for tracked windows that are unminimized but not currently in any zone.
extension AppController {
    /// Iterates tracked windows that are unminimized but not assigned to any zone (tiled or floating), and applies
    /// the provided handler to each validated candidate.
    ///
    /// This helper centralizes the candidate-gathering + revalidation pattern used by recapture and other flows
    /// that must place "tracked but unzoned" windows without relying on timing-sensitive event ordering.
    @discardableResult
    internal func withTrackedButUnzonedWindows(
        reason: String,
        candidateKind: String,
        allowedWindowIds: Set<Int>? = nil,
        _ handler: (ManagedWindow) -> Void
    ) -> Int {
        var placedCount = 0

        let candidateWindowIds: [Int] = windowController.allWindows.compactMap { (window: ManagedWindow) -> Int? in
            if let allowedWindowIds, !allowedWindowIds.contains(window.windowId) {
                return nil
            }

            guard !window.isMinimizedPerAccessibility,
                  zoneKey(forManagedWindow: window) == nil,
                  !isWindowInFloatingZone(window.windowId) else {
                return nil
            }

            return window.windowId
        }.sorted()

        for windowId in candidateWindowIds {
            // Re-resolve each candidate from the registry so callers never place a window object
            // that was pruned after candidate collection.
            guard let window = windowController.window(withId: windowId) else {
                Logger.debug("\(reason.capitalized): skipping \(candidateKind) candidate \(windowId); no longer managed")
                continue
            }

            guard !window.isMinimizedPerAccessibility,
                  zoneKey(forManagedWindow: window) == nil,
                  !isWindowInFloatingZone(windowId) else {
                continue
            }

            handler(window)

            if window.zoneIndex != nil || isWindowInFloatingZone(window.windowId) {
                placedCount += 1
            }
        }

        return placedCount
    }
}
