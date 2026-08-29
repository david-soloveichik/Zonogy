import Foundation

/// Pure gate deciding whether a window's AX move may participate in manual-drag detection.
/// One left button means one gesture: a block through mouse-up (a cursor-driven chooser-row
/// drag claimed the button, or a cancelled gesture must not restart) excludes every window,
/// and a live drag excludes every other window.
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
}
