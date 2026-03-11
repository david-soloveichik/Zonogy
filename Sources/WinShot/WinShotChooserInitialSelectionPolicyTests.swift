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

        func signature(
            presentZoneIndices: [Int],
            tiledWindowIdsByZoneIndex: [Int: Int],
            floatingZoneWindowId: Int? = nil
        ) -> WinShotSnapshotOccupancySignature {
            WinShotSnapshotOccupancySignature(
                presentZoneIndices: presentZoneIndices,
                tiledWindowIdsByZoneIndex: tiledWindowIdsByZoneIndex,
                floatingZoneWindowId: floatingZoneWindowId
            )
        }

        do {
            let current = signature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 1, 2: 2]
            )
            let signatures: [WinShotSnapshotOccupancySignature] = [
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 1, 2: 2]),
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 3]),
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [2: 4], floatingZoneWindowId: 5)
            ]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(
                snapshotOccupancySignatures: signatures,
                currentOccupancySignature: current
            )
            assert(index == 1, "should skip the most recent snapshot when it matches current occupancy")
        }

        do {
            let current = signature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 1, 2: 2]
            )
            let signatures: [WinShotSnapshotOccupancySignature] = [
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 3]),
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 1, 2: 2])
            ]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(
                snapshotOccupancySignatures: signatures,
                currentOccupancySignature: current
            )
            assert(index == 0, "should keep index 0 when it differs from current occupancy")
        }

        do {
            let current = signature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 1, 2: 2]
            )
            let signatures: [WinShotSnapshotOccupancySignature] = [
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 1, 2: 2])
            ]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(
                snapshotOccupancySignatures: signatures,
                currentOccupancySignature: current
            )
            assert(index == 0, "should fall back to 0 when no other snapshot exists")
        }

        do {
            let current = signature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 1, 2: 2]
            )
            let signatures: [WinShotSnapshotOccupancySignature] = [
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 1, 2: 2]),
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 1, 2: 2]),
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 9])
            ]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(
                snapshotOccupancySignatures: signatures,
                currentOccupancySignature: current
            )
            assert(index == 2, "should select the first snapshot that differs from current occupancy")
        }

        do {
            let current = signature(
                presentZoneIndices: [1],
                tiledWindowIdsByZoneIndex: [:]
            )
            let signatures: [WinShotSnapshotOccupancySignature] = [
                signature(presentZoneIndices: [1], tiledWindowIdsByZoneIndex: [1: 101])
            ]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(
                snapshotOccupancySignatures: signatures,
                currentOccupancySignature: current
            )
            assert(index == 0, "empty current set should still select the first snapshot")
        }

        do {
            let current = signature(
                presentZoneIndices: [1],
                tiledWindowIdsByZoneIndex: [1: 1]
            )
            let signatures: [WinShotSnapshotOccupancySignature] = []
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(
                snapshotOccupancySignatures: signatures,
                currentOccupancySignature: current
            )
            assert(index == 0, "empty snapshot list should return 0")
        }

        do {
            let current = signature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 1, 2: 2]
            )
            let signatures: [WinShotSnapshotOccupancySignature] = [
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 2, 2: 1]),
                signature(presentZoneIndices: [1, 2], tiledWindowIdsByZoneIndex: [1: 1, 2: 2])
            ]
            let index = WinShotChooserInitialSelectionPolicy.initialSelectedIndex(
                snapshotOccupancySignatures: signatures,
                currentOccupancySignature: current
            )
            assert(index == 0, "same windows in different zones should count as a different snapshot")
        }

        if allPassed {
            print("WinShotChooserInitialSelectionPolicyTests: all tests passed")
        }
        return allPassed
    }
}
