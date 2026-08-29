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
            blocked: Bool = false,
            cursorActive: Bool = false,
            current: Int? = nil
        ) -> ManualDragGatePolicy.Gate {
            ManualDragGatePolicy.gate(
                windowId: windowId,
                blockedUntilMouseUp: blocked,
                cursorDrivenDragActive: cursorActive,
                currentDraggingWindowId: current
            )
        }

        assert(gate() == .mayBecomeCandidate, "a clean gesture state should allow candidacy")
        assert(gate(blocked: true) == .blocked, "a block through mouse-up should block every window")
        assert(gate(cursorActive: true) == .blocked, "an active cursor-driven row drag should block every window")
        assert(gate(current: 1) == .continueCurrentDrag, "the window with the live drag should continue it")
        assert(gate(current: 2) == .blocked, "another window's live drag should block candidacy")
        assert(gate(blocked: true, current: 1) == .blocked, "the block should outrank even the live drag's continuation")

        if allPassed {
            print("ManualDragGatePolicyTests: all tests passed")
        }
        return allPassed
    }
}
