import Foundation
import AppKit

/// Shared placement helpers for tracked windows that are unminimized but not currently in any zone.
extension AppController {
    /// Iterates tracked windows that are unminimized but not assigned to any zone (tiled or temporary), and applies
    /// the provided handler to each validated candidate.
    ///
    /// This helper centralizes the candidate-gathering + revalidation pattern used by recapture and other flows
    /// that must place "tracked but unzoned" windows without relying on timing-sensitive event ordering.
    @discardableResult
    internal func withTrackedButUnzonedWindows(
        reason: String,
        candidateKind: String,
        restrictedToScreenId: CGDirectDisplayID? = nil,
        skipFullScreenPausedScreens: Bool,
        logSkipFullScreenPaused: Bool,
        _ handler: (ManagedWindow) -> Void
    ) -> Int {
        var placedCount = 0

        let candidateWindowIds: [Int] = windowController.allWindows.compactMap { (window: ManagedWindow) -> Int? in
            guard !window.isMinimizedPerAccessibility,
                  zoneKey(forManagedWindow: window) == nil,
                  !isWindowInTemporaryZone(window.windowId) else {
                return nil
            }

            if let restrictedToScreenId {
                guard detectScreenId(for: window) == restrictedToScreenId else {
                    return nil
                }
            }

            if skipFullScreenPausedScreens,
               let screenId = detectScreenId(for: window),
               isScreenPausedForFullScreen(screenId) {
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
                  !isWindowInTemporaryZone(windowId) else {
                continue
            }

            if let restrictedToScreenId,
               detectScreenId(for: window) != restrictedToScreenId {
                continue
            }

            if skipFullScreenPausedScreens,
               let screenId = detectScreenId(for: window),
               isScreenPausedForFullScreen(screenId) {
                if logSkipFullScreenPaused {
                    Logger.debug(
                        "\(reason.capitalized): skipping \(candidateKind) candidate \(windowId) " +
                            "on full-screen screen \(screenContextStore.loggingIndex(for: screenId))"
                    )
                }
                continue
            }

            handler(window)

            if window.zoneIndex != nil || isWindowInTemporaryZone(window.windowId) {
                placedCount += 1
            }
        }

        return placedCount
    }
}

