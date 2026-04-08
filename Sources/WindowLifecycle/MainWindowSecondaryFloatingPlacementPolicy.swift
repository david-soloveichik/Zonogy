import Foundation

/// Pure selection logic for the has-main-window secondary-window floating exception.
enum MainWindowSecondaryFloatingPlacementPolicy {
    struct CandidateWindow {
        let windowId: Int
        let cgWindowId: Int
    }

    static func shouldRedirectToFloating(
        hasMainWindow: Bool,
        floatsSecondaryWindowsWhenMainWindowIsTargeted: Bool,
        incomingWindowId: Int,
        targetedZoneOccupantWindowId: Int?,
        sameAppWindows: [CandidateWindow]
    ) -> Bool {
        guard hasMainWindow,
              floatsSecondaryWindowsWhenMainWindowIsTargeted,
              let targetedZoneOccupantWindowId,
              targetedZoneOccupantWindowId != incomingWindowId else {
            return false
        }

        let sortedWindows = sameAppWindows.sorted { lhs, rhs in
            if lhs.cgWindowId == rhs.cgWindowId {
                return lhs.windowId < rhs.windowId
            }
            return lhs.cgWindowId < rhs.cgWindowId
        }

        guard let mainWindow = sortedWindows.first else {
            return false
        }

        guard mainWindow.windowId == targetedZoneOccupantWindowId else {
            return false
        }

        return sortedWindows.contains(where: { $0.windowId == incomingWindowId })
    }
}
