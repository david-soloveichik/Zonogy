import Foundation

/// Pure position/width-coincidence matching for native macOS tabs, which Accessibility exposes as
/// separate windows: adopting a switched-to tab into an existing zone occupant, and rebinding a
/// zone occupant to a surviving sibling tab when the tab currently backing it is closed. Height is
/// never compared (see `positionAndWidthCoincide`).
enum NativeTabReplacementPolicy {
    struct Candidate: Equatable {
        let windowId: Int
        let pid: pid_t
        let cgWindowId: Int
        let frame: CGRect
        let isPlacedInZone: Bool
    }

    /// A surviving same-process window considered when the tab currently backing a managed
    /// window is closed. Unlike `Candidate`, these are not managed windows, so they carry
    /// only a CGWindowID and a live frame.
    struct SiblingCandidate: Equatable {
        let cgWindowId: Int
        let frame: CGRect
    }

    static let frameTolerance: CGFloat = 2.0

    static func shouldEvaluateIncomingWindow(
        isPlacedInZone: Bool,
        isMinimized: Bool,
        nativeTabHandlingDisabled: Bool
    ) -> Bool {
        !nativeTabHandlingDisabled && !isMinimized && !isPlacedInZone
    }

    /// Pick the placed managed window a switched-to tab should be adopted into. Matches on
    /// position and width only (see `positionAndWidthCoincide`). The live-frame check upstream has
    /// already excluded separate live windows, so the remaining candidates are switched-away tabs;
    /// among those an exact position/width match identifies the window.
    static func replacementCandidate(
        incomingPid: pid_t,
        incomingCgWindowId: Int,
        incomingFrame: CGRect,
        candidates: [Candidate],
        frameTolerance: CGFloat = Self.frameTolerance
    ) -> Candidate? {
        candidates
            .filter { candidate in
                candidate.pid == incomingPid &&
                candidate.cgWindowId != incomingCgWindowId &&
                candidate.isPlacedInZone &&
                positionAndWidthCoincide(
                    incomingFrame,
                    candidate.frame,
                    tolerance: frameTolerance
                )
            }
            .min { lhs, rhs in
                let lhsScore = coincidenceScore(incomingFrame, lhs.frame)
                let rhsScore = coincidenceScore(incomingFrame, rhs.frame)
                if lhsScore != rhsScore {
                    return lhsScore < rhsScore
                }
                return lhs.windowId < rhs.windowId
            }
    }

    /// Among surviving sibling windows, pick the one whose frame still coincides with the closed
    /// window's last cached frame. Matches on position and width only, like the switch case. Ties
    /// break toward the closest frame, then the lowest CGWindowID, so selection is deterministic.
    static func bestSibling(
        matching cachedFrame: CGRect,
        among candidates: [SiblingCandidate],
        frameTolerance: CGFloat = Self.frameTolerance
    ) -> SiblingCandidate? {
        candidates
            .filter { candidate in
                positionAndWidthCoincide(
                    cachedFrame,
                    candidate.frame,
                    tolerance: frameTolerance
                )
            }
            .min { lhs, rhs in
                let lhsScore = coincidenceScore(cachedFrame, lhs.frame)
                let rhsScore = coincidenceScore(cachedFrame, rhs.frame)
                if lhsScore != rhsScore {
                    return lhsScore < rhsScore
                }
                return lhs.cgWindowId < rhs.cgWindowId
            }
    }

    /// Position and width coincidence within rounding tolerance, ignoring height. Both the switch
    /// (adoption) and close (sibling) matches use this. Height is deliberately not compared: a
    /// resize that lands on the active tab can leave a tracked tab's height stale, which would
    /// otherwise block a correct match, and exact position+width coincidence is already a strong
    /// same-window signal.
    static func positionAndWidthCoincide(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = Self.frameTolerance
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
        abs(lhs.minY - rhs.minY) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance
    }

    private static func coincidenceScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) +
        abs(lhs.minY - rhs.minY) +
        abs(lhs.width - rhs.width)
    }
}
