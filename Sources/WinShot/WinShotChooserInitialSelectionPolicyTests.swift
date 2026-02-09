import Foundation

/// Guardrail tests for WinShot chooser initial-selection policy.
enum WinShotChooserInitialSelectionPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotChooserInitialSelectionPolicyTests: \(message)")
                allPassed = false
            }
        }

        do {
            let current: Set<Int> = [1, 2]
            let sets: [Set<Int>] = [[1, 2], [3], [4, 5]]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(snapshotWindowSets: sets, currentWindowIds: current)
            assert(index == 1, "should skip the most recent snapshot when it matches current windows")
        }

        do {
            let current: Set<Int> = [1, 2]
            let sets: [Set<Int>] = [[3], [1, 2]]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(snapshotWindowSets: sets, currentWindowIds: current)
            assert(index == 0, "should keep index 0 when it differs from current windows")
        }

        do {
            let current: Set<Int> = [1, 2]
            let sets: [Set<Int>] = [[1, 2]]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(snapshotWindowSets: sets, currentWindowIds: current)
            assert(index == 0, "should fall back to 0 when no other snapshot exists")
        }

        do {
            let current: Set<Int> = [1, 2]
            let sets: [Set<Int>] = [[1, 2], [1, 2], [9]]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(snapshotWindowSets: sets, currentWindowIds: current)
            assert(index == 2, "should select the first snapshot that differs from current windows")
        }

        do {
            let current: Set<Int> = []
            let sets: [Set<Int>] = [[101]]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(snapshotWindowSets: sets, currentWindowIds: current)
            assert(index == 0, "empty current set should still select the first snapshot")
        }

        do {
            let current: Set<Int> = [1]
            let sets: [Set<Int>] = []
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(snapshotWindowSets: sets, currentWindowIds: current)
            assert(index == 0, "empty snapshot list should return 0")
        }

        if allPassed {
            print("WinShotChooserInitialSelectionPolicyTests: all tests passed")
        }
        return allPassed
    }
}

