/// Determines which WinShot snapshot should be initially selected when opening the chooser.
import Foundation

enum WinShotChooserInitialSelectionPolicy {
    /// Computes the initial selection index for a recency-ordered list of snapshots (newest first).
    ///
    /// If the most recent snapshot matches the current window set, select the next snapshot so a
    /// single invocation behaves like Command-Tab (toggle to the most recent *other* snapshot).
    static func initialSelectedIndex(snapshotWindowSets: [Set<Int>], currentWindowIds: Set<Int>) -> Int {
        guard !snapshotWindowSets.isEmpty else {
            return 0
        }

        return snapshotWindowSets.firstIndex(where: { $0 != currentWindowIds }) ?? 0
    }
}

