import Foundation

/// Guardrail tests for CmdTab initial-selection policy.
enum CmdTabInitialSelectionPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("CmdTabInitialSelectionPolicyTests: \(message)")
                allPassed = false
            }
        }

        func index(_ ids: [Int?], frontmost: Int? = nil, skip: Set<Int> = []) -> Int {
            CmdTabInitialSelectionPolicy.initialSelectedIndex(
                orderedWindowIds: ids,
                frontmostWindowId: frontmost,
                skipWindowIds: skip
            )
        }

        // Default rule (no skips) must match the historical behavior exactly.
        assert(index([1, 2, 3], frontmost: 1) == 1, "frontmost first should select the second entry")
        assert(index([1, 2, 3]) == 0, "no frontmost window should select the first entry")
        assert(index([1, 2, 3], frontmost: 3) == 0, "frontmost deeper in the list should still select the first entry")
        assert(index([1], frontmost: 1) == 0, "single frontmost window should clamp to index 0")
        assert(index([]) == 0, "empty list should return 0")

        // Just-minimized skips.
        assert(index([9, 2, 3], skip: [9]) == 1, "skip-marked first entry should select the second entry")
        assert(
            index([5, 9, 3], frontmost: 5, skip: [9]) == 2,
            "sibling focused after minimize: skip both the frontmost and the marked window"
        )
        assert(index([9, 8, 3], skip: [9, 8]) == 2, "multiple just-minimized windows should all be skipped")
        assert(
            index([9, 2, 5], frontmost: 5, skip: [9]) == 1,
            "frontmost deeper in the list should be skipped during the scan"
        )
        assert(index([1, 2, 3], frontmost: 1, skip: [7]) == 1, "skips absent from the list should not change the default")

        // Fallback when skipping eliminates every entry.
        assert(index([9], skip: [9]) == 0, "sole marked window should fall back to index 0")
        assert(index([5, 9], frontmost: 5, skip: [9]) == 1, "all entries skipped should fall back to the default rule")

        // Entries without a managed window id are selectable.
        assert(index([nil, 9, 3], skip: [9]) == 0, "nil-id entry should be treated as a normal candidate")

        if allPassed {
            print("CmdTabInitialSelectionPolicyTests: all tests passed")
        }
        return allPassed
    }
}
