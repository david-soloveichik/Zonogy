import Foundation

/// Guardrail tests for `ManualDragGatePolicy`, the gesture-ownership gate for manual-drag
/// detection.
enum ManualDragGatePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ManualDragGatePolicyTests: \(message)")
                allPassed = false
            }
        }

        func gate(
            windowId: Int = 1,
            suppressed: Bool = false,
            cursorActive: Bool = false,
            tombstoned: Int? = nil,
            current: Int? = nil
        ) -> ManualDragGatePolicy.Gate {
            ManualDragGatePolicy.gate(
                windowId: windowId,
                suppressedUntilMouseUp: suppressed,
                cursorDrivenDragActive: cursorActive,
                tombstonedWindowId: tombstoned,
                currentDraggingWindowId: current
            )
        }

        assert(gate() == .mayBecomeCandidate, "a clean gesture state should allow candidacy")
        assert(gate(suppressed: true) == .blocked, "suppression through mouse-up should block every window")
        assert(gate(cursorActive: true) == .blocked, "an active cursor-driven row drag should block every window")
        assert(gate(tombstoned: 2) == .blocked, "any live tombstone should block every window, not just its own")
        assert(gate(current: 1) == .continueCurrentDrag, "the window with the live drag should continue it")
        assert(gate(current: 2) == .blocked, "another window's live drag should block candidacy")
        assert(gate(suppressed: true, current: 1) == .blocked, "suppression should outrank even the live drag's continuation")
        assert(gate(tombstoned: 1, current: 1) == .blocked, "a tombstone should outrank a (stale) matching live drag")

        if allPassed {
            print("ManualDragGatePolicyTests: all tests passed")
        }
        return allPassed
    }
}
