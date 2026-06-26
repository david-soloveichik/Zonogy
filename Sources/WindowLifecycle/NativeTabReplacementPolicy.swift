import Foundation

/// Pure matching policy for detecting native macOS tab switches exposed as fresh CGWindowIDs.
enum NativeTabReplacementPolicy {
    struct Candidate: Equatable {
        let windowId: Int
        let pid: pid_t
        let cgWindowId: Int
        let frame: CGRect
        let isPlacedInZone: Bool
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
