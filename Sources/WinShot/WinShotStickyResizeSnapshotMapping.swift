import CoreGraphics

/// Pure helpers for saving and restoring Sticky Resize remembered sizes in WinShot snapshots.
enum WinShotStickyResizeSnapshotMapping {
    static func snapshotSizesByZoneIndex(
        zoneAssignments: [Int: WindowIdentity],
        rememberedSizesByWindowId: [Int: CGSize]
    ) -> [Int: CGSize] {
        var result: [Int: CGSize] = [:]

        for (zoneIndex, identity) in zoneAssignments {
            guard let size = rememberedSizesByWindowId[identity.windowId],
                  size.width > 0,
                  size.height > 0 else {
                continue
            }
            result[zoneIndex] = size
        }

        return result
    }

    static func restoredSizesByWindowId(
        snapshotSizesByZoneIndex: [Int: CGSize],
        restoredWindowIdsByZoneIndex: [Int: Int]
    ) -> [Int: CGSize] {
        var result: [Int: CGSize] = [:]

        for (zoneIndex, windowId) in restoredWindowIdsByZoneIndex {
            guard let size = snapshotSizesByZoneIndex[zoneIndex],
                  size.width > 0,
                  size.height > 0 else {
                continue
            }
            result[windowId] = size
        }

        return result
    }
}
