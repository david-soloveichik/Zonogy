import Foundation

/// Guardrail tests for `DisplacedWindowPlanner` to ensure shared displacement behavior stays consistent.
enum DisplacedWindowPlannerTests {
    private struct StubWindow: WindowIdProviding {
        let windowId: Int
    }

    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("DisplacedWindowPlannerTests: \(message)")
                allPassed = false
            }
        }

        do {
            var events: [String] = []
            let plan = DisplacedWindowPlanner.planIfNeeded(
                existingWindowId: nil,
                incomingWindowId: 1,
                lookupWindow: { (_: Int) -> StubWindow? in nil },
                evictExistingWindowId: { _ in events.append("evict") },
                clearDisplacedAssignment: { (_: StubWindow) in events.append("clear") },
                finalizeDisplaced: { (_: StubWindow) in events.append("finalize") }
            )
            assert(plan == nil, "no occupant should produce no plan")
            assert(events.isEmpty, "no occupant should not call any hooks")
        }

        do {
            var events: [String] = []
            let plan = DisplacedWindowPlanner.planIfNeeded(
                existingWindowId: 10,
                incomingWindowId: 10,
                lookupWindow: { _ in StubWindow(windowId: 10) },
                evictExistingWindowId: { _ in events.append("evict") },
                clearDisplacedAssignment: { _ in events.append("clear") },
                finalizeDisplaced: { _ in events.append("finalize") }
            )
            assert(plan == nil, "same-window replacement should be a no-op")
            assert(events.isEmpty, "same-window replacement should not call any hooks")
        }

        do {
            var events: [String] = []
            let plan = DisplacedWindowPlanner.planIfNeeded(
                existingWindowId: 99,
                incomingWindowId: 1,
                lookupWindow: { (_: Int) -> StubWindow? in nil },
                evictExistingWindowId: { id in events.append("evict \(id)") },
                clearDisplacedAssignment: { (_: StubWindow) in events.append("clear") },
                finalizeDisplaced: { (_: StubWindow) in events.append("finalize") }
            )
            assert(plan == nil, "missing occupant lookup should not produce a plan")
            assert(events == ["evict 99"], "missing lookup should still evict")
        }

        do {
            var events: [String] = []
            let plan = DisplacedWindowPlanner.planIfNeeded(
                existingWindowId: 42,
                incomingWindowId: 1,
                lookupWindow: { id in StubWindow(windowId: id) },
                evictExistingWindowId: { id in events.append("evict \(id)") },
                clearDisplacedAssignment: { win in events.append("clear \(win.windowId)") },
                finalizeDisplaced: { win in events.append("finalize \(win.windowId)") }
            )
            assert(plan?.displaced.windowId == 42, "plan should contain displaced window")
            assert(events == ["evict 42", "clear 42"], "planning should evict then clear assignment")
            plan?.finalize()
            assert(events == ["evict 42", "clear 42", "finalize 42"], "finalize should run after planning side effects")
        }

        if allPassed {
            print("DisplacedWindowPlannerTests: all tests passed")
        }
        return allPassed
    }
}
