/// Determines which WinShot snapshot should be initially selected when opening the chooser.

enum WinShotChooserInitialSelectionPolicy {
    /// Computes the initial selection index for a recency-ordered list of snapshots (newest first).
    ///
    /// If the most recent snapshot matches the current occupancy signature, select the next snapshot so a
    /// single invocation behaves like Command-Tab (toggle to the most recent *other* snapshot).
    static func initialSelectedIndex(
        snapshotOccupancySignatures: [WinShotSnapshotOccupancySignature],
        currentOccupancySignature: WinShotSnapshotOccupancySignature
    ) -> Int {
        guard !snapshotOccupancySignatures.isEmpty else {
            return 0
        }

        return snapshotOccupancySignatures.firstIndex(where: { $0 != currentOccupancySignature }) ?? 0
    }
}
