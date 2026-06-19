import Foundation

/// Guardrail tests for WinShot chooser in-place selection restoration.
enum WinShotChooserSelectionRestorePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotChooserSelectionRestorePolicyTests: \(message)")
                allPassed = false
            }
        }

        let a = UUID(), b = UUID(), c = UUID(), d = UUID()

        // Selected snapshot survives: follow it to its new index.
        assert(
            WinShotChooserSelectionRestorePolicy.restoredSelectionIndex(
                previousSelectedId: c, previousSelectedIndex: 2, newSnapshotIds: [a, b, c]
            ) == 2,
            "surviving selection should map to its new index"
        )
        // ...even when its index shifted (a newer snapshot was inserted at the front).
        assert(
            WinShotChooserSelectionRestorePolicy.restoredSelectionIndex(
                previousSelectedId: b, previousSelectedIndex: 0, newSnapshotIds: [d, a, b, c]
            ) == 2,
            "surviving selection should be found by id, not stale index"
        )

        // Selected snapshot deleted: stay at the same position (now the next/adjacent one).
        assert(
            WinShotChooserSelectionRestorePolicy.restoredSelectionIndex(
                previousSelectedId: b, previousSelectedIndex: 1, newSnapshotIds: [a, c, d]
            ) == 1,
            "deleted selection should keep the same strip position"
        )

        // Deleted the last (oldest) snapshot: clamp to the new last index.
        assert(
            WinShotChooserSelectionRestorePolicy.restoredSelectionIndex(
                previousSelectedId: c, previousSelectedIndex: 2, newSnapshotIds: [a, b]
            ) == 1,
            "deleting the last selection should clamp to the new last index"
        )

        // No previous selection info: default to the newest.
        assert(
            WinShotChooserSelectionRestorePolicy.restoredSelectionIndex(
                previousSelectedId: nil, previousSelectedIndex: nil, newSnapshotIds: [a, b]
            ) == 0,
            "missing selection info should default to index 0"
        )

        // Empty new list: nothing to select.
        assert(
            WinShotChooserSelectionRestorePolicy.restoredSelectionIndex(
                previousSelectedId: a, previousSelectedIndex: 0, newSnapshotIds: []
            ) == nil,
            "empty snapshot list should return nil"
        )

        if allPassed {
            print("WinShotChooserSelectionRestorePolicyTests: all tests passed")
        }
        return allPassed
    }
}
