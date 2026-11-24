import Foundation

/// Pure rules for manual-drag detection: the gate deciding whether a window's AX move may
/// participate, and when a candidate's moves start the drag. One left button means one gesture:
/// a block through mouse-up (a cursor-driven chooser-row drag claimed the button, or a cancelled
/// gesture must not restart) excludes every window, and a live drag excludes every other window.
enum ManualDragGatePolicy {
    enum Gate: Equatable {
        /// The window's live manual drag continues.
        case continueCurrentDrag
        /// The window may become (or advance) a drag candidate.
        case mayBecomeCandidate
        /// No manual-drag processing for this window right now.
        case blocked
    }

    static func gate(
        windowId: Int,
        blockedUntilMouseUp: Bool,
        cursorDrivenDragActive: Bool,
        currentDraggingWindowId: Int?
    ) -> Gate {
        if blockedUntilMouseUp || cursorDrivenDragActive {
            return .blocked
        }
        if currentDraggingWindowId == windowId {
            return .continueCurrentDrag
        }
        if currentDraggingWindowId != nil {
            return .blocked
        }
        return .mayBecomeCandidate
    }

    /// The frame a candidate's movement counts from: the earliest frame observed since the window's
    /// size last changed, starting with the frame observed before this report. Only movement at an
    /// unchanged size counts, since a resize from the left or top edge moves the window too.
    /// Counting from the frame before the first report matters because macOS can stop reporting a
    /// dragged window's moves once the pointer crosses onto another display, so that report may be
    /// the only one. The cost: a drag whose window changes size in the last report it gets (a large
    /// window shrunk as it crosses onto a smaller display) does not start.
    static func candidateOrigin(candidateOrigin: CGRect?, previousFrame: CGRect?, frame: CGRect) -> CGRect {
        if let previousFrame, previousFrame.size != frame.size {
            return frame
        }
        if let candidateOrigin, candidateOrigin.size == frame.size {
            return candidateOrigin
        }
        return previousFrame ?? frame
    }

    /// Whether a move from `origin` to `frame` is far enough to start the drag.
    static func startsDrag(origin: CGRect, frame: CGRect, threshold: CGFloat) -> Bool {
        hypot(frame.midX - origin.midX, frame.midY - origin.midY) >= threshold
    }
}
