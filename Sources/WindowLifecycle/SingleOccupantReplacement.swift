import Foundation

/// Shared replacement pipeline for destinations that can hold at most one window (tiled zone or temporary zone).
///
/// This standardizes the ordering so both pathways behave consistently:
/// 1) Evict and clear the displaced occupant (if any)
/// 2) Assign the incoming window
/// 3) Perform any post-assignment actions (e.g., activation/protection)
/// 4) Finalize the displaced follow-up action (e.g., deferred minimization)
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

        assignIncoming()
        afterAssignIncoming()
        plan?.finalize()

        return plan?.displaced
    }
}

