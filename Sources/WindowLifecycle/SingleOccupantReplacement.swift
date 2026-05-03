import Foundation

/// Shared replacement pipeline for destinations that can hold at most one window (tiled zone or floating zone).
///
/// Ordering:
/// 1) Evict and clear the displaced occupant's bookkeeping (data only).
/// 2) Finalize the displaced follow-up action (e.g., synchronous minimize) BEFORE the
///    incoming window's frame/raise writes. This matters when `finalizeDisplaced`
///    performs a synchronous AX minimize: `kAXMinimizedAttribute = true` briefly
///    raises the displaced window to key before the genie animation. If the incoming
///    window has already been positioned/raised at that point (e.g., an already-
///    visible window being moved between zones, or a freshly unminimized window
///    when pre-position is disabled), the displaced window's flash-to-key would
///    appear above it. Running finalize first keeps the flash invisible.
/// 3) Assign the incoming window (frame writes, raise).
/// 4) Perform any post-assignment actions (e.g., activation/protection).
enum SingleOccupantReplacement {
    @discardableResult
    static func replaceIfNeeded<Window: WindowIdProviding>(
        existingWindowId: Int?,
        incomingWindowId: Int,
        lookupWindow: (Int) -> Window?,
        evictExistingWindowId: (Int) -> Void,
        clearDisplacedAssignment: (Window) -> Void,
        finalizeDisplaced: @escaping (Window) -> Void,
        assignIncoming: () -> Void,
        afterAssignIncoming: () -> Void = {}
    ) -> Window? {
        let plan = DisplacedWindowPlanner.planIfNeeded(
            existingWindowId: existingWindowId,
            incomingWindowId: incomingWindowId,
            lookupWindow: lookupWindow,
            evictExistingWindowId: evictExistingWindowId,
            clearDisplacedAssignment: clearDisplacedAssignment,
            finalizeDisplaced: finalizeDisplaced
        )

        plan?.finalize()
        assignIncoming()
        afterAssignIncoming()

        return plan?.displaced
    }
}

