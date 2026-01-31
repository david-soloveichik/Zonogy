import Foundation

/// Guardrail tests for `SingleOccupantReplacement` to ensure ordering stays consistent.
enum SingleOccupantReplacementTests {
    private struct StubWindow: WindowIdProviding {
        let windowId: Int
    }

    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("SingleOccupantReplacementTests: \(message)")
                allPassed = false
            }
        }

        do {
            var events: [String] = []
            let existingId = 10
            _ = SingleOccupantReplacement.replaceIfNeeded(
                existingWindowId: existingId,
                incomingWindowId: 20,
                lookupWindow: { StubWindow(windowId: $0) },
                evictExistingWindowId: { _ in events.append("evict") },
                clearDisplacedAssignment: { _ in events.append("clear-displaced") },
                finalizeDisplaced: { _ in events.append("finalize-displaced") },
                assignIncoming: { events.append("assign-incoming") },
                afterAssignIncoming: { events.append("after-assign") }
            )
            assert(
                events == ["evict", "clear-displaced", "assign-incoming", "after-assign", "finalize-displaced"],
                "expected replacement ordering to be stable (got \(events))"
            )
        }

        do {
            var events: [String] = []
            let existingId = 10
            _ = SingleOccupantReplacement.replaceIfNeeded(
                existingWindowId: existingId,
                incomingWindowId: 20,
                lookupWindow: { (_: Int) in nil as StubWindow? },
                evictExistingWindowId: { _ in events.append("evict") },
                clearDisplacedAssignment: { _ in events.append("clear-displaced") },
                finalizeDisplaced: { _ in events.append("finalize-displaced") },
                assignIncoming: { events.append("assign-incoming") },
                afterAssignIncoming: { events.append("after-assign") }
            )
            assert(
                events == ["evict", "assign-incoming", "after-assign"],
                "expected replacement ordering when existing window can't be looked up (got \(events))"
            )
        }

        do {
            var events: [String] = []
            _ = SingleOccupantReplacement.replaceIfNeeded(
                existingWindowId: nil,
                incomingWindowId: 20,
                lookupWindow: { StubWindow(windowId: $0) },
                evictExistingWindowId: { _ in events.append("evict") },
                clearDisplacedAssignment: { _ in events.append("clear-displaced") },
                finalizeDisplaced: { _ in events.append("finalize-displaced") },
                assignIncoming: { events.append("assign-incoming") },
                afterAssignIncoming: { events.append("after-assign") }
            )
            assert(
                events == ["assign-incoming", "after-assign"],
                "expected no displacement hooks when there's no existing occupant (got \(events))"
            )
        }

        if allPassed {
            print("SingleOccupantReplacementTests: all tests passed")
        }
        return allPassed
    }
}
