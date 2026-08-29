import Foundation

/// Pure gate deciding whether a window's AX move may participate in manual-drag detection.
/// One left button means one gesture: a cursor-driven chooser-row drag or a cancelled
/// gesture's tombstone owns the button through its mouse-up, and a live drag excludes every
/// other window.
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
        suppressedUntilMouseUp: Bool,
        cursorDrivenDragActive: Bool,
        tombstonedWindowId: Int?,
        currentDraggingWindowId: Int?
    ) -> Gate {
        if suppressedUntilMouseUp || cursorDrivenDragActive {
            return .blocked
        }
        if tombstonedWindowId != nil {
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
