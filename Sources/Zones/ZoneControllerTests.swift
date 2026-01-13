import Foundation
import CoreGraphics

/// Lightweight runtime assertions for ZoneController occupant and resizing behavior.
enum ZoneControllerTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ZoneControllerTests: \(message)")
                allPassed = false
            }
        }

        func assertApproximatelyEqual(_ actual: CGFloat, _ expected: CGFloat, label: String, tolerance: CGFloat = 0.5) {
            if abs(actual - expected) > tolerance {
                print("ZoneControllerTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
            }
        }

        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 1)
            assert(controller.allZones.count == 1, "init should create 1 zone")
            assert(controller.zone(at: 1)?.index == 1, "zone 1 should exist")

            controller.assignWindow(windowId: 101, toZoneIndex: 1)
            _ = controller.addZone()
            assert(controller.allZones.count == 2, "addZone should increase zone count")
            assert(controller.zone(at: 1)?.occupantWindowId == 101, "addZone should preserve occupant in zone 1")
            assert(controller.zone(at: 2)?.occupantWindowId == nil, "new zone should be empty")

            controller.assignWindow(windowId: 202, toZoneIndex: 2)
            _ = controller.addZone()
            assert(controller.allZones.count == 3, "addZone should increase zone count to 3")
            assert(controller.zone(at: 1)?.occupantWindowId == 101, "zone 1 occupant should remain after adding third zone")
            assert(controller.zone(at: 2)?.occupantWindowId == 202, "zone 2 occupant should remain after adding third zone")
            assert(controller.zone(at: 3)?.occupantWindowId == nil, "zone 3 should start empty")

            controller.assignWindow(windowId: 303, toZoneIndex: 3)
            let removal = controller.removeZone(at: 2)
            assert(removal?.removedWindowId == 202, "removeZone should report removed zone's occupant")
            assert(controller.allZones.count == 2, "removeZone should decrease zone count")
            assert(controller.zone(at: 1)?.occupantWindowId == 101, "zone 1 occupant should remain after removing middle zone")
            assert(controller.zone(at: 2)?.occupantWindowId == 303, "zone 3 occupant should shift into zone 2 after removal")
        }

        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 3)
            controller.assignWindow(windowId: 401, toZoneIndex: 1)
            controller.assignWindow(windowId: 402, toZoneIndex: 2)
            controller.assignWindow(windowId: 403, toZoneIndex: 3)

            let removed = controller.setZoneCount(to: 1)
            assert(Set(removed) == Set([402, 403]), "setZoneCount should return removed window IDs when reducing")
            assert(controller.allZones.count == 1, "setZoneCount should reduce zones")
            assert(controller.zone(at: 1)?.occupantWindowId == 401, "setZoneCount should preserve lowest-index occupant")
        }

        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 2)
            controller.assignWindow(windowId: 501, toZoneIndex: 1)

            let originalLeft = controller.zone(at: 1)!.frame
            let originalRight = controller.zone(at: 2)!.frame

            let attempted = controller.resizeZone(at: 1, to: CGRect(x: 0, y: 0, width: 700, height: 800))
            assert(attempted == false, "resizeZone should reject resizing an occupied zone by default")

            let currentLeft = controller.zone(at: 1)!.frame
            let currentRight = controller.zone(at: 2)!.frame
            assert(currentLeft.equalTo(originalLeft), "occupied resize attempt should not change zone 1 frame")
            assert(currentRight.equalTo(originalRight), "occupied resize attempt should not change zone 2 frame")
        }

        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 2)
            let resized = controller.resizeZone(at: 1, to: CGRect(x: 0, y: 0, width: 1, height: 800))
            assert(resized == true, "resizeZone should allow resizing an empty zone")

            let leftWidth = controller.zone(at: 1)!.frame.width
            let expectedMinWidth = screen.width * 0.1
            assertApproximatelyEqual(leftWidth, expectedMinWidth, label: "resizeZone should clamp to minimum width ratio")
        }

        if allPassed {
            print("ZoneControllerTests: all tests passed")
        }
        return allPassed
    }
}
