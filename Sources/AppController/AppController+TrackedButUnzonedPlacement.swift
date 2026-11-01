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

            // Zonogy's records first, so only windows in no zone cost a round trip to their
            // application (this runs on every Space change).
            guard zoneKey(forManagedWindow: window) == nil,
                  !isWindowInFloatingZone(window.windowId),
                  !isAwaitingMinimization(window),
                  !window.isMinimizedPerAccessibility else {
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

            guard zoneKey(forManagedWindow: window) == nil,
                  !isWindowInFloatingZone(windowId),
                  !window.isMinimizedPerAccessibility else {
                continue
            }

            handler(window)

            if window.zoneIndex != nil || isWindowInFloatingZone(window.windowId) {
                placedCount += 1
            }
        }

        return placedCount
    }

    /// Windows Zonogy is about to minimize are not waiting for placement: displaced windows in the
    /// deferred queue (placing one would put it back over the incoming window), and windows from a
    /// disconnected display leaving full-screen first.
    private func isAwaitingMinimization(_ window: ManagedWindow) -> Bool {
        deferredMinimizationCoordinator.isPending(windowId: window.windowId)
            || windowsLeavingFullScreenToMinimize.contains(CGWindowID(window.backing.cgWindowId))
    }
}
