import Foundation

/// Pure selection logic for choosing which tiling zone a removal shortcut should remove.
enum ZoneShortcutRemovalPolicy {
    struct ZoneSnapshot: Equatable {
        let index: Int
        let isEmpty: Bool
        let occupantWindowId: Int?
    }

    static func selectedZoneIndex(
        zones: [ZoneSnapshot],
        protectedIndices: Set<Int>,
        targetedIndex: Int?
    ) -> Int? {
        orderedCandidates(
            zones: zones,
            protectedIndices: protectedIndices,
            targetedIndex: targetedIndex
        ).first?.index
    }

    static func orderedCandidates(
        zones: [ZoneSnapshot],
        protectedIndices: Set<Int>,
        targetedIndex: Int?
    ) -> [ZoneSnapshot] {
        zones
            .filter { !protectedIndices.contains($0.index) }
            .sorted { lhs, rhs in
                priorityKey(for: lhs, targetedIndex: targetedIndex) <
                    priorityKey(for: rhs, targetedIndex: targetedIndex)
            }
    }

    static func priorityKey(
        for zone: ZoneSnapshot,
        targetedIndex: Int?
    ) -> (Int, Int, Int) {
        let emptinessRank = zone.isEmpty ? 0 : 1
        let targetedRank = (targetedIndex == zone.index) ? 1 : 0
        let indexRank = -zone.index
        return (emptinessRank, targetedRank, indexRank)
    }
}
