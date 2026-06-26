import Foundation

/// Pure frame-coincidence matching for native macOS tabs, which Accessibility exposes as
/// separate windows: adopting a switched-to tab into an existing zone occupant, and rebinding
/// a zone occupant to a surviving sibling tab when the tab currently backing it is closed.
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
    static let heightTolerance: CGFloat = 50.0

    static func shouldEvaluateIncomingWindow(
        isPlacedInZone: Bool,
        isMinimized: Bool,
        nativeTabHandlingDisabled: Bool
    ) -> Bool {
        !nativeTabHandlingDisabled && !isMinimized && !isPlacedInZone
    }

    static func replacementCandidate(
        incomingPid: pid_t,
        incomingCgWindowId: Int,
        incomingFrame: CGRect,
        candidates: [Candidate],
        frameTolerance: CGFloat = Self.frameTolerance,
        heightTolerance: CGFloat = Self.heightTolerance
    ) -> Candidate? {
        candidates
            .filter { candidate in
                candidate.pid == incomingPid &&
                candidate.cgWindowId != incomingCgWindowId &&
                candidate.isPlacedInZone &&
                framesCoincide(
                    incomingFrame,
                    candidate.frame,
                    frameTolerance: frameTolerance,
                    heightTolerance: heightTolerance
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

    /// Among surviving sibling windows, pick the one whose frame still coincides with the
    /// closed window's last cached frame. Ties break toward the closest frame, then the lowest
    /// CGWindowID, so selection is deterministic.
    static func bestSibling(
        matching cachedFrame: CGRect,
        among candidates: [SiblingCandidate],
        frameTolerance: CGFloat = Self.frameTolerance,
        heightTolerance: CGFloat = Self.heightTolerance
    ) -> SiblingCandidate? {
        candidates
            .filter { candidate in
                framesCoincide(
                    cachedFrame,
                    candidate.frame,
                    frameTolerance: frameTolerance,
                    heightTolerance: heightTolerance
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

    static func framesCoincide(
        _ lhs: CGRect,
        _ rhs: CGRect,
        frameTolerance: CGFloat = Self.frameTolerance,
        heightTolerance: CGFloat = Self.heightTolerance
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= frameTolerance &&
        abs(lhs.minY - rhs.minY) <= frameTolerance &&
        abs(lhs.width - rhs.width) <= frameTolerance &&
        abs(lhs.height - rhs.height) <= heightTolerance
    }

    private static func coincidenceScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) +
        abs(lhs.minY - rhs.minY) +
        abs(lhs.width - rhs.width) +
        abs(lhs.height - rhs.height)
    }
}
