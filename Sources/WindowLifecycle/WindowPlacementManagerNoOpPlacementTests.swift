import Foundation
import CoreGraphics

/// Guardrail tests for `WindowPlacementManager` no-op placement detection.
enum WindowPlacementManagerNoOpPlacementTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WindowPlacementManagerNoOpPlacementTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2

        do {
            let destination = ZoneKey(screenId: screen1, index: 1)
            let result = WindowPlacementManager.isNoOpTiledPlacement(
                windowId: 100,
                currentZoneIndex: 1,
                currentScreenId: screen1,
                destinationKey: destination,
                destinationOccupantWindowId: 100
            )
            assert(result, "expected no-op placement when window assignment matches destination and destination occupant matches windowId")
        }

        do {
            let destination = ZoneKey(screenId: screen1, index: 1)
            let result = WindowPlacementManager.isNoOpTiledPlacement(
                windowId: 100,
                currentZoneIndex: 1,
                currentScreenId: screen1,
                destinationKey: destination,
                destinationOccupantWindowId: 101
            )
            assert(!result, "expected non-no-op placement when destination occupant differs")
        }

        do {
            let destination = ZoneKey(screenId: screen1, index: 1)
            let result = WindowPlacementManager.isNoOpTiledPlacement(
                windowId: 100,
                currentZoneIndex: 1,
                currentScreenId: screen2,
                destinationKey: destination,
                destinationOccupantWindowId: 100
            )
            assert(!result, "expected non-no-op placement when the window is on a different screen")
        }

        do {
            let destination = ZoneKey(screenId: screen1, index: 1)
            let result = WindowPlacementManager.isNoOpTiledPlacement(
                windowId: 100,
                currentZoneIndex: nil,
                currentScreenId: screen1,
                destinationKey: destination,
                destinationOccupantWindowId: 100
            )
            assert(!result, "expected non-no-op placement when the window is not currently assigned to a tiled zone")
        }

        if allPassed {
            print("WindowPlacementManagerNoOpPlacementTests: all tests passed")
        }
        return allPassed
    }
}

