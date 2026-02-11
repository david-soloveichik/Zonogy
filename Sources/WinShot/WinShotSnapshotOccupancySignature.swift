/// Canonical occupancy signature used to detect duplicate WinShot snapshots.

struct WinShotSnapshotOccupancySignature: Equatable {
    /// Zone indices present in the layout (including empty zones).
    let presentZoneIndices: Set<Int>
    /// Tiled-zone occupant window IDs keyed by zone index.
    let tiledWindowIdsByZoneIndex: [Int: Int]
    /// Temporary-zone occupant window ID, if any.
    let temporaryZoneWindowId: Int?

    init<S: Sequence>(
        presentZoneIndices: S,
        tiledWindowIdsByZoneIndex: [Int: Int],
        temporaryZoneWindowId: Int?
    ) where S.Element == Int {
        self.presentZoneIndices = Set(presentZoneIndices)
        self.tiledWindowIdsByZoneIndex = tiledWindowIdsByZoneIndex
        self.temporaryZoneWindowId = temporaryZoneWindowId
    }

    init(snapshot: WinShotSnapshot) {
        self.init(
            presentZoneIndices: snapshot.zoneFrames.keys,
            tiledWindowIdsByZoneIndex: snapshot.zoneAssignments.mapValues { $0.windowId },
            temporaryZoneWindowId: snapshot.temporaryZoneOccupant?.windowId
        )
    }
}
