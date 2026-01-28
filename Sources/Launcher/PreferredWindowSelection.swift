import Foundation

/// Pure selection logic for choosing a preferred managed window for the Launcher.
///
/// This logic is intentionally isolated so it can be covered by guardrail tests and reused by callers
/// that have already filtered down to "eligible" windows.
enum PreferredWindowSelection {
    struct Candidate: Equatable {
        let windowId: Int
        let cgWindowId: Int
        let lastActiveTime: Date?
    }

    static func selectPreferredWindow(from candidates: [Candidate], prefersMainWindow: Bool) -> Candidate? {
        guard !candidates.isEmpty else {
            return nil
        }

        var sorted = candidates

        if prefersMainWindow {
            sorted.sort { lhs, rhs in
                let lhsWindowServerId = lhs.cgWindowId > 0 ? lhs.cgWindowId : Int.max
                let rhsWindowServerId = rhs.cgWindowId > 0 ? rhs.cgWindowId : Int.max

                if lhsWindowServerId != rhsWindowServerId {
                    return lhsWindowServerId < rhsWindowServerId
                }
                return lhs.windowId < rhs.windowId
            }
            return sorted.first
        }

        // Most recent first, falling back to Zonogy ID order when recency is unknown.
        sorted.sort { lhs, rhs in
            switch (lhs.lastActiveTime, rhs.lastActiveTime) {
            case (let lhsT?, let rhsT?):
                return lhsT > rhsT
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.windowId < rhs.windowId
            }
        }

        return sorted.first
    }
}

