import CoreGraphics
import Foundation

/// Guardrail tests for the snapshot occupant ordering that drives the chooser app-icon row.
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

        // Tiling zones in ascending index order, floating-zone occupant appended last.
        assert(snapshot(zones: [3: 30, 1: 10, 2: 20], floating: 99).occupantsByZoneOrder.map(\.windowId) == [10, 20, 30, 99],
               "tiling zones ascending by index, floating occupant last")

        // No floating occupant: tiling zones only.
        assert(snapshot(zones: [2: 20, 1: 10], floating: nil).occupantsByZoneOrder.map(\.windowId) == [10, 20],
               "no floating occupant yields tiling zones only")

        // Floating-only snapshot yields just the floating occupant.
        assert(snapshot(zones: [:], floating: 99).occupantsByZoneOrder.map(\.windowId) == [99],
               "floating-only snapshot yields the floating occupant")

        if allPassed {
            print("WinShotSnapshotOccupantOrderTests: all tests passed")
        }
        return allPassed
    }
}
