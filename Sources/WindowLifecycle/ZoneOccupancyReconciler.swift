import Foundation

/// Pure reconciliation helper that identifies stale zone occupant IDs.
enum ZoneOccupancyReconciler {
    struct ZoneOccupantSnapshot: Equatable {
        let key: ZoneKey
        let occupantWindowId: Int?
    }

    struct StaleOccupant: Equatable {
        let key: ZoneKey
        let windowId: Int
    }

    static func staleOccupants(
        from snapshots: [ZoneOccupantSnapshot],
        liveWindowIds: Set<Int>
    ) -> [StaleOccupant] {
        snapshots.compactMap { snapshot in
            guard let occupantId = snapshot.occupantWindowId,
                  !liveWindowIds.contains(occupantId) else {
                return nil
            }
            return StaleOccupant(key: snapshot.key, windowId: occupantId)
        }
    }
}
