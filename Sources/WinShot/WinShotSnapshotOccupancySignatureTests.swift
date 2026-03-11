import Foundation

/// Guardrail tests for WinShot duplicate-snapshot occupancy signatures.
enum WinShotSnapshotOccupancySignatureTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotSnapshotOccupancySignatureTests: \(message)")
                allPassed = false
            }
        }

        do {
            let lhs = WinShotSnapshotOccupancySignature(
                presentZoneIndices: [1, 2, 3],
                tiledWindowIdsByZoneIndex: [1: 101, 3: 102],
                floatingZoneWindowId: nil
            )
            let rhs = WinShotSnapshotOccupancySignature(
                presentZoneIndices: [3, 2, 1],
                tiledWindowIdsByZoneIndex: [3: 102, 1: 101],
                floatingZoneWindowId: nil
            )
            assert(lhs == rhs, "identical occupancy should compare equal")
        }

        do {
            let lhs = WinShotSnapshotOccupancySignature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 201, 2: 202],
                floatingZoneWindowId: nil
            )
            let rhs = WinShotSnapshotOccupancySignature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 202, 2: 201],
                floatingZoneWindowId: nil
            )
            assert(lhs != rhs, "window-to-zone assignment should affect equality")
        }

        do {
            let lhs = WinShotSnapshotOccupancySignature(
                presentZoneIndices: [1, 2, 3],
                tiledWindowIdsByZoneIndex: [1: 301],
                floatingZoneWindowId: nil
            )
            let rhs = WinShotSnapshotOccupancySignature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 301],
                floatingZoneWindowId: nil
            )
            assert(lhs != rhs, "present-but-empty zones should affect equality")
        }

        do {
            let lhs = WinShotSnapshotOccupancySignature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 401],
                floatingZoneWindowId: nil
            )
            let rhs = WinShotSnapshotOccupancySignature(
                presentZoneIndices: [1, 2],
                tiledWindowIdsByZoneIndex: [1: 401],
                floatingZoneWindowId: 402
            )
            assert(lhs != rhs, "floating-zone occupancy should affect equality")
        }

        if allPassed {
            print("WinShotSnapshotOccupancySignatureTests: all tests passed")
        }
        return allPassed
    }
}
