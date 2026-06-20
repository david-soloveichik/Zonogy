import CoreGraphics
import Foundation

/// Guardrail tests for the tiling-zone occupant ordering that drives the chooser's top app-icon row.
enum WinShotSnapshotOccupantOrderTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotSnapshotOccupantOrderTests: \(message)")
                allPassed = false
            }
        }

        func identity(_ windowId: Int) -> WindowIdentity {
            WindowIdentity(
                windowId: windowId,
                externalIdentifier: ExternalWindowIdentifier(pid: 0, cgWindowId: windowId),
                bundleIdentifier: "app.\(windowId)",
                windowTitle: nil
            )
        }

        func snapshot(zones: [Int: Int], floating: Int?) -> WinShotSnapshot {
            WinShotSnapshot(
                id: UUID(),
                screenId: 0,
                createdAt: Date(timeIntervalSinceReferenceDate: 0),
                lastActiveAt: Date(timeIntervalSinceReferenceDate: 0),
                zoneCount: zones.count,
                zoneFrames: Dictionary(uniqueKeysWithValues: zones.keys.map { ($0, CGRect.zero) }),
                windowFrames: [:],
                rememberedTiledWindowSizesByZoneIndex: [:],
                zoneAssignments: zones.mapValues { identity($0) },
                floatingZoneOccupant: floating.map { identity($0) },
                floatingZoneFrame: nil,
                activeWindowId: nil,
                thumbnail: nil
            )
        }

        // Tiling zones in ascending index order; the floating-zone occupant is excluded (it is shown
        // on a separate row).
        assert(snapshot(zones: [3: 30, 1: 10, 2: 20], floating: 99).tilingOccupantsByZoneOrder.map(\.windowId) == [10, 20, 30],
               "tiling zones ascending by index, floating occupant excluded")

        // No floating occupant: tiling zones in ascending order.
        assert(snapshot(zones: [2: 20, 1: 10], floating: nil).tilingOccupantsByZoneOrder.map(\.windowId) == [10, 20],
               "tiling zones ascending by index")

        // Floating-only snapshot has no tiling occupants.
        assert(snapshot(zones: [:], floating: 99).tilingOccupantsByZoneOrder.isEmpty,
               "floating-only snapshot has no tiling occupants")

        if allPassed {
            print("WinShotSnapshotOccupantOrderTests: all tests passed")
        }
        return allPassed
    }
}
