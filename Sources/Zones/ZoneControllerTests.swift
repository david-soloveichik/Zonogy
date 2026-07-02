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
            controller.assignWindow(windowId: 601, toZoneIndex: 1)
            controller.assignWindow(windowId: 603, toZoneIndex: 3)

            let removal = controller.removeZone(at: 2)
            assert(removal?.removedWindowId == nil, "removing an empty middle zone should not report a removed occupant")
            assert(controller.allZones.count == 2, "removing an empty middle zone should decrease zone count")
            assert(controller.zone(at: 1)?.occupantWindowId == 601, "zone 1 occupant should remain after removing empty middle zone")
            assert(controller.zone(at: 2)?.occupantWindowId == 603, "higher-index survivor should collapse inward after removing empty middle zone")
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

        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 3)
            controller.replaceZones(withOccupants: [902, nil])

            assert(controller.allZones.count == 2, "replaceZones should update the zone count")
            assert(controller.zone(at: 1)?.occupantWindowId == 902, "replaceZones should preserve explicit zone 1 occupant")
            assert(controller.zone(at: 2)?.occupantWindowId == nil, "replaceZones should preserve explicit empty zones")
            assert(controller.zone(at: 3) == nil, "replaceZones should drop unspecified trailing zones")
        }

        // Single-bar styles force canonical sides: right-bar puts zone 1 left, left-bar mirrors.
        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 3)
            assert(controller.zone(at: 1)?.side == .left, "right-bar zone 1 side should be left")
            assert(controller.zone(at: 2)?.side == .right, "right-bar zone 2 side should be right")
            assert(controller.zone(at: 3)?.side == .right, "right-bar zone 3 side should be right")
            assert(controller.canAddZone(on: .right) == false, "right-bar at 3 zones has no capacity")
        }

        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 3, layoutStyle: .leftBar)
            assert(controller.zone(at: 1)?.side == .right, "left-bar zone 1 side should be right (mirror)")
            assert(controller.zone(at: 2)?.side == .left, "left-bar zone 2 side should be left")
            assert(controller.zone(at: 3)?.side == .left, "left-bar zone 3 side should be left")
            let zone1 = controller.zone(at: 1)!
            let zone2 = controller.zone(at: 2)!
            assert(zone1.frame.minX > zone2.frame.minX, "left-bar zone 1 should sit to the right of zone 2")
        }

        // Dual-bar: splitting a lone zone gives the new zone the clicked side and moves the
        // existing zone (and its occupant) to the other side.
        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 1, layoutStyle: .dualBar)
            controller.assignWindow(windowId: 700, toZoneIndex: 1)
            assert(controller.canAddZone(on: .left) && controller.canAddZone(on: .right), "dual-bar lone zone leaves both sides addable")

            let newZone = controller.addZone(preferredSide: .left)
            assert(newZone?.index == 2, "new zone should take the highest index")
            assert(newZone?.side == .left, "new zone should take the clicked side")
            assert(controller.zone(at: 1)?.side == .right, "existing zone should flip to the other side")
            assert(controller.zone(at: 1)?.occupantWindowId == 700, "existing occupant should stay in zone 1")
        }

        // Dual-bar: adding to a side stacks it (existing zone on top), up to 2 per side and 4 total.
        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 1, layoutStyle: .dualBar)
            _ = controller.addZone(preferredSide: .right)   // zones: 1 left | 2 right
            _ = controller.addZone(preferredSide: .right)   // right stacks: 2 top, 3 bottom
            assert(controller.zone(at: 3)?.side == .right, "third zone joins the right side")
            let zone2 = controller.zone(at: 2)!
            let zone3 = controller.zone(at: 3)!
            assert(zone2.frame.minY < zone3.frame.minY, "existing right zone stays on top; new zone takes the bottom")
            assert(controller.canAddZone(on: .right) == false, "right side is full at 2 zones")
            assert(controller.canAddZone(on: .left) == true, "left side still has capacity")
            assert(controller.addZone(preferredSide: .right) == nil, "adding to a full side should fail")

            let fourth = controller.addZone(preferredSide: .left)
            assert(fourth?.index == 4 && fourth?.side == .left, "fourth zone joins the left side")
            assert(controller.allZones.count == 4, "dual-bar allows 4 zones")
            assert(controller.addZone(preferredSide: .left) == nil, "dual-bar caps at 4 zones")
            let zone1 = controller.zone(at: 1)!
            let zone4 = controller.zone(at: 4)!
            assert(zone1.frame.minY < zone4.frame.minY, "left stack keeps zone 1 on top of zone 4")
        }

        // Dual-bar removal: emptying a column re-tiles the two survivors side-by-side
        // (lower index left), instead of leaving a full-width stack.
        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 1, layoutStyle: .dualBar)
            _ = controller.addZone(preferredSide: .left)    // zones: 1 right | 2 left
            _ = controller.addZone(preferredSide: .left)    // left stacks: 2 top, 3 bottom
            controller.assignWindow(windowId: 801, toZoneIndex: 2)
            controller.assignWindow(windowId: 802, toZoneIndex: 3)

            _ = controller.removeZone(at: 1)                // right column empties
            assert(controller.allZones.count == 2, "two survivors after removal")
            assert(controller.zone(at: 1)?.side == .left, "survivors re-tile one per side (zone 1 left)")
            assert(controller.zone(at: 2)?.side == .right, "survivors re-tile one per side (zone 2 right)")
            assert(controller.zone(at: 1)?.occupantWindowId == 801, "survivor occupants keep index order")
            assert(controller.zone(at: 2)?.occupantWindowId == 802, "survivor occupants keep index order")
        }

        // Dual-bar removal within a stacked side: the sibling keeps the column (no re-tile).
        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 1, layoutStyle: .dualBar)
            _ = controller.addZone(preferredSide: .right)
            _ = controller.addZone(preferredSide: .right)   // 1 left | 2 right-top, 3 right-bottom
            _ = controller.removeZone(at: 2)
            assert(controller.zone(at: 1)?.side == .left, "left zone keeps its side")
            assert(controller.zone(at: 2)?.side == .right, "right survivor keeps its side")
            let rightZone = controller.zone(at: 2)!
            assertApproximatelyEqual(rightZone.frame.height, screen.height, label: "right survivor expands to full column height")
        }

        // Style switching re-tiles in place, dropping zones beyond the new maximum.
        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 1, layoutStyle: .dualBar)
            _ = controller.addZone(preferredSide: .right)
            _ = controller.addZone(preferredSide: .right)
            _ = controller.addZone(preferredSide: .left)
            controller.assignWindow(windowId: 901, toZoneIndex: 1)
            controller.assignWindow(windowId: 904, toZoneIndex: 4)

            let removed = controller.setLayoutStyle(.rightBar)
            assert(removed == [904], "switching below the zone count drops the highest-index zone's occupant")
            assert(controller.allZones.count == 3, "switching to a single-bar style clamps to 3 zones")
            assert(controller.zone(at: 1)?.side == .left, "right-bar canonical sides after switch")
            assert(controller.zone(at: 2)?.side == .right, "right-bar canonical sides after switch")
            assert(controller.zone(at: 3)?.side == .right, "right-bar canonical sides after switch")
            assert(controller.zone(at: 1)?.occupantWindowId == 901, "occupants keep their zone index across a switch")
        }

        // Switching into dual-bar keeps the current arrangement (zero movement).
        do {
            let controller = ZoneController(screenFrame: screen, initialZoneCount: 3, layoutStyle: .leftBar)
            let framesBefore = controller.allZones.sorted { $0.index < $1.index }.map { $0.frame }
            _ = controller.setLayoutStyle(.dualBar)
            let framesAfter = controller.allZones.sorted { $0.index < $1.index }.map { $0.frame }
            assert(framesBefore == framesAfter, "switching into dual-bar should not move zones")
            assert(controller.canAddZone(on: .right) == true, "dual-bar opens capacity on the right (single-zone side)")
        }

        if allPassed {
            print("ZoneControllerTests: all tests passed")
        }
        return allPassed
    }
}
