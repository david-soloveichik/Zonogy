import Foundation

/// Minimal protocol for types that represent windows by a stable `windowId`.
/// This is intentionally decoupled from Accessibility/AppKit so it can be exercised
/// by guardrail tests with simple stubs.
protocol WindowIdProviding {
    var windowId: Int { get }
}

extension ManagedWindow: WindowIdProviding {}

/// Represents a displaced occupant window and the caller-controlled follow-up action
/// (e.g., minimize immediately, queue deferred minimization, or reassign elsewhere).
struct DisplacedWindowPlan<Window: WindowIdProviding> {
    let displaced: Window
    let finalize: () -> Void
}

/// Shared displacement planning used by both tiled-zone and temporary-zone placement.
enum DisplacedWindowPlanner {
    /// If `existingWindowId` refers to an occupant different from `incomingWindowId`, evict it from the destination,
    /// clear its assignment bookkeeping, and return a plan the caller can `finalize()` at the appropriate time.
    ///
    /// If the occupant cannot be looked up, it is still evicted and the method returns `nil`.
    static func planIfNeeded<Window: WindowIdProviding>(
        existingWindowId: Int?,
        incomingWindowId: Int,
        lookupWindow: (Int) -> Window?,
        evictExistingWindowId: (Int) -> Void,
        clearDisplacedAssignment: (Window) -> Void,
        finalizeDisplaced: @escaping (Window) -> Void
    ) -> DisplacedWindowPlan<Window>? {
        guard let existingWindowId, existingWindowId != incomingWindowId else {
            return nil
        }

        guard let displaced = lookupWindow(existingWindowId) else {
            evictExistingWindowId(existingWindowId)
            return nil
        }

        evictExistingWindowId(existingWindowId)
        clearDisplacedAssignment(displaced)

        return DisplacedWindowPlan(displaced: displaced) {
            finalizeDisplaced(displaced)
        }
    }
}

