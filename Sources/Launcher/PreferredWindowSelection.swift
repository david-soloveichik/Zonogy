import Foundation

/// Pure selection logic for choosing an app's preferred managed window (Launcher and DockMenus).
///
/// This logic is intentionally isolated so it can be covered by guardrail tests and reused by callers
/// that have already filtered down to "eligible" windows.
enum PreferredWindowSelection {
    struct Candidate: Equatable {
        let windowId: Int
        let cgWindowId: Int
        let isPlacedInZone: Bool
        let lastActiveTime: Date?
    }

    /// - Parameters:
    ///   - prefersMainWindow: The app's main window (lowest CGWindowID) wins.
    ///   - placedMainWindowYields: A main window already placed in a zone does not win; the
    ///     selection falls back to the ordering used for apps without a main window.
    static func selectPreferredWindow(
        from candidates: [Candidate],
        prefersMainWindow: Bool,
        placedMainWindowYields: Bool
    ) -> Candidate? {
        if prefersMainWindow,
           let mainWindow = mainWindow(in: candidates),
           !(placedMainWindowYields && mainWindow.isPlacedInZone) {
            return mainWindow
        }

        // Match Launcher drill-down ordering: windows not in any zone first, then the shared
        // recency order (most recently active first, Zonogy ID for ties and unknown recency).
        return candidates.min { lhs, rhs in
            if lhs.isPlacedInZone != rhs.isPlacedInZone {
                return !lhs.isPlacedInZone && rhs.isPlacedInZone
            }
            return ManagedWindowRecencyOrder.isMoreRecent(
                windowId: lhs.windowId,
                lastActiveTime: lhs.lastActiveTime,
                than: rhs.windowId,
                otherLastActiveTime: rhs.lastActiveTime
            )
        }
    }

    /// Lowest CGWindowID (unknown IDs last), then lowest Zonogy ID.
    private static func mainWindow(in candidates: [Candidate]) -> Candidate? {
        candidates.min { lhs, rhs in
            let lhsWindowServerId = lhs.cgWindowId > 0 ? lhs.cgWindowId : Int.max
            let rhsWindowServerId = rhs.cgWindowId > 0 ? rhs.cgWindowId : Int.max

            if lhsWindowServerId != rhsWindowServerId {
                return lhsWindowServerId < rhsWindowServerId
            }
            return lhs.windowId < rhs.windowId
        }
    }
}
