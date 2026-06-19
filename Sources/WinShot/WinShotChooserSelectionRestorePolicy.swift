/// Determines which WinShot snapshot stays selected when the chooser is refreshed in place
/// (e.g. an auto-saved snapshot arrives, or a snapshot is deleted) while it is open.
import Foundation

enum WinShotChooserSelectionRestorePolicy {
    /// Index to select after an in-place refresh, given the previously selected snapshot's id
    /// and index plus the new snapshot ids (display order, newest first).
    ///
    /// Prefers the same snapshot when it survives the refresh; otherwise keeps the same position
    /// in the strip (clamped to the new bounds) rather than jumping to the newest. Returns nil
    /// when the new list is empty (nothing to select).
    static func restoredSelectionIndex(
        previousSelectedId: UUID?,
        previousSelectedIndex: Int?,
        newSnapshotIds: [UUID]
    ) -> Int? {
        guard !newSnapshotIds.isEmpty else {
            return nil
        }

        if let previousSelectedId,
           let survivingIndex = newSnapshotIds.firstIndex(of: previousSelectedId) {
            return survivingIndex
        }

        if let previousSelectedIndex {
            return min(max(previousSelectedIndex, 0), newSnapshotIds.count - 1)
        }

        return 0
    }
}
