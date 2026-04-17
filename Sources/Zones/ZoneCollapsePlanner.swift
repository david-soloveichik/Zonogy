import Foundation

/// Pure planner for collapsing a screen's tiling zones as far as shortcut policy allows.
enum ZoneCollapsePlanner {
    struct ZoneSnapshot: Equatable {
        let index: Int
        let occupantWindowId: Int?

        var isEmpty: Bool { occupantWindowId == nil }
    }

    struct Plan: Equatable {
        let finalZones: [ZoneSnapshot]
        let removedWindowIds: [Int]
        let finalTargetIndex: Int?
    }

    static func plan(
        zones: [ZoneSnapshot],
        protectedWindowIds: Set<Int>,
        targetedIndex: Int?
    ) -> Plan {
        var currentZones = zones.sorted { $0.index < $1.index }
        var currentTargetIndex = targetedIndex
        var removedWindowIds: [Int] = []

        while currentZones.count > 1 {
            let protectedIndices: Set<Int> = Set(
                currentZones.compactMap { zone in
                    guard let occupantWindowId = zone.occupantWindowId,
                          protectedWindowIds.contains(occupantWindowId) else {
                        return nil
                    }
                    return zone.index
                }
            )

            let removalCandidates = currentZones.map { zone in
                ZoneShortcutRemovalPolicy.ZoneSnapshot(
                    index: zone.index,
                    isEmpty: zone.isEmpty,
                    occupantWindowId: zone.occupantWindowId
                )
            }

            guard let removalIndex = ZoneShortcutRemovalPolicy.selectedZoneIndex(
                zones: removalCandidates,
                protectedIndices: protectedIndices,
                targetedIndex: currentTargetIndex
            ),
            let removalArrayIndex = currentZones.firstIndex(where: { $0.index == removalIndex }) else {
                break
            }

            let removedZone = currentZones.remove(at: removalArrayIndex)
            if let removedWindowId = removedZone.occupantWindowId {
                removedWindowIds.append(removedWindowId)
            }

            if let targetIndex = currentTargetIndex {
                if targetIndex == removalIndex {
                    currentTargetIndex = nil
                } else if targetIndex > removalIndex {
                    currentTargetIndex = targetIndex - 1
                }
            }

            currentZones = currentZones.enumerated().map { offset, zone in
                ZoneSnapshot(index: offset + 1, occupantWindowId: zone.occupantWindowId)
            }
        }

        return Plan(
            finalZones: currentZones,
            removedWindowIds: removedWindowIds,
            finalTargetIndex: currentTargetIndex
        )
    }
}
