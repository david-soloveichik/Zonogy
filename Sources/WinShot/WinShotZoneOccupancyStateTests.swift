import Foundation
import CoreGraphics

/// Guardrail tests for WinShot occupancy-change detection.
enum WinShotZoneOccupancyStateTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotZoneOccupancyStateTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2

        do {
            let previous: [CGDirectDisplayID: WinShotZoneOccupancyState] = [
                screen1: WinShotZoneOccupancyState(
                    tiledOccupantsByZoneIndex: [1: 101, 2: 102],
                    temporaryOccupantWindowId: nil
                )
            ]
            let current = previous
            let changed = WinShotZoneOccupancyChangeDetector.changedScreenIds(previous: previous, current: current)
            assert(changed.isEmpty, "identical occupancy should not be treated as a change")
        }

        do {
            let previous: [CGDirectDisplayID: WinShotZoneOccupancyState] = [
                screen1: WinShotZoneOccupancyState(
                    tiledOccupantsByZoneIndex: [1: 201, 2: 202],
                    temporaryOccupantWindowId: nil
                )
            ]
            let current: [CGDirectDisplayID: WinShotZoneOccupancyState] = [
                screen1: WinShotZoneOccupancyState(
                    tiledOccupantsByZoneIndex: [1: 202, 2: 201],
                    temporaryOccupantWindowId: nil
                )
            ]
            let changed = WinShotZoneOccupancyChangeDetector.changedScreenIds(previous: previous, current: current)
            assert(changed == [screen1], "moving windows between zones should be detected as an occupancy change")
        }

        do {
            let previous: [CGDirectDisplayID: WinShotZoneOccupancyState] = [
                screen1: WinShotZoneOccupancyState(
                    tiledOccupantsByZoneIndex: [1: 301],
                    temporaryOccupantWindowId: nil
                )
            ]
            let current: [CGDirectDisplayID: WinShotZoneOccupancyState] = [
                screen1: WinShotZoneOccupancyState(
                    tiledOccupantsByZoneIndex: [1: 301],
                    temporaryOccupantWindowId: 302
                )
            ]
            let changed = WinShotZoneOccupancyChangeDetector.changedScreenIds(previous: previous, current: current)
            assert(changed == [screen1], "temporary-zone occupancy changes should be detected")
        }

        do {
            let previous: [CGDirectDisplayID: WinShotZoneOccupancyState] = [
                screen1: WinShotZoneOccupancyState(
                    tiledOccupantsByZoneIndex: [1: 401],
                    temporaryOccupantWindowId: nil
                )
            ]
            let current: [CGDirectDisplayID: WinShotZoneOccupancyState] = [
                screen1: WinShotZoneOccupancyState(
                    tiledOccupantsByZoneIndex: [1: 401],
                    temporaryOccupantWindowId: nil
                ),
                screen2: WinShotZoneOccupancyState(
                    tiledOccupantsByZoneIndex: [1: 402],
                    temporaryOccupantWindowId: nil
                )
            ]
            let changed = WinShotZoneOccupancyChangeDetector.changedScreenIds(previous: previous, current: current)
            assert(changed == [screen2], "adding a screen occupancy entry should be detected")
        }

        if allPassed {
            print("WinShotZoneOccupancyStateTests: all tests passed")
        }
        return allPassed
    }
}
