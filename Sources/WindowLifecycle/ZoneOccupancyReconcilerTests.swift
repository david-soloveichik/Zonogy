import Foundation
import CoreGraphics

/// Guardrail tests for stale zone-occupancy reconciliation.
enum ZoneOccupancyReconcilerTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ZoneOccupancyReconcilerTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2

        do {
            let snapshots = [
                ZoneOccupancyReconciler.ZoneOccupantSnapshot(
                    key: ZoneKey(screenId: screen1, index: 1),
                    occupantWindowId: 101
                ),
                ZoneOccupancyReconciler.ZoneOccupantSnapshot(
                    key: ZoneKey(screenId: screen1, index: 2),
                    occupantWindowId: nil
                )
            ]
            let stale = ZoneOccupancyReconciler.staleOccupants(
                from: snapshots,
                liveWindowIds: [101]
            )
            assert(stale.isEmpty, "live occupants should not be marked stale")
        }

        do {
            let snapshots = [
                ZoneOccupancyReconciler.ZoneOccupantSnapshot(
                    key: ZoneKey(screenId: screen1, index: 1),
                    occupantWindowId: 201
                ),
                ZoneOccupancyReconciler.ZoneOccupantSnapshot(
                    key: ZoneKey(screenId: screen2, index: 1),
                    occupantWindowId: 202
                )
            ]
            let stale = ZoneOccupancyReconciler.staleOccupants(
                from: snapshots,
                liveWindowIds: [202]
            )
            let expected = [
                ZoneOccupancyReconciler.StaleOccupant(
                    key: ZoneKey(screenId: screen1, index: 1),
                    windowId: 201
                )
            ]
            assert(stale == expected, "missing occupant should be marked stale")
        }

        do {
            let snapshots = [
                ZoneOccupancyReconciler.ZoneOccupantSnapshot(
                    key: ZoneKey(screenId: screen1, index: 1),
                    occupantWindowId: 301
                ),
                ZoneOccupancyReconciler.ZoneOccupantSnapshot(
                    key: ZoneKey(screenId: screen1, index: 2),
                    occupantWindowId: 301
                )
            ]
            let stale = ZoneOccupancyReconciler.staleOccupants(
                from: snapshots,
                liveWindowIds: []
            )
            assert(stale.count == 2, "duplicate stale occupants should be reported per zone")
            assert(stale[0].key == ZoneKey(screenId: screen1, index: 1), "first stale zone key mismatch")
            assert(stale[1].key == ZoneKey(screenId: screen1, index: 2), "second stale zone key mismatch")
        }

        if allPassed {
            print("ZoneOccupancyReconcilerTests: all tests passed")
        }
        return allPassed
    }
}
