import Foundation
import CoreGraphics

/// Lightweight runtime assertions for TargetedZoneManager selection invariants.
enum TargetedZoneManagerTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("TargetedZoneManagerTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )

            // Simulate screen removal (target is still on screen1, but it no longer exists).
            delegate.screenContexts.removeValue(forKey: screen1)
            manager.ensureTargetedZone(reason: "repair")

            let expected = ZoneKey(screenId: screen2, index: 1)
            assert(manager.targetedZoneKey == expected, "ensureTargetedZone should prefer an empty tiling zone on another screen when the preferred screen disappears (got \(String(describing: manager.targetedZoneKey)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2, screen2: 2],
                screenOrder: [screen1, screen2]
            )
            let controller1 = delegate.zoneController(for: screen1)!
            let controller2 = delegate.zoneController(for: screen2)!

            controller1.assignWindow(windowId: 501, toZoneIndex: 2)
            controller2.assignWindow(windowId: 601, toZoneIndex: 2)

            let preferred = manager.lowestIndexEmptyZone(preferredScreenId: screen2)
            let expectedPreferred = ZoneKey(screenId: screen2, index: 1)
            assert(preferred == expectedPreferred, "lowestIndexEmptyZone should honor preferred screen when indexes tie (got \(String(describing: preferred)))")

            // With unequal indexes, the globally lowest index wins over the preferred screen —
            // callers wanting a same-screen preference must try lowestIndexEmptyZoneOnSameScreen first.
            controller2.removeWindow(windowId: 601)
            controller2.assignWindow(windowId: 601, toZoneIndex: 1)
            let global = manager.lowestIndexEmptyZone(preferredScreenId: screen2)
            assert(global == ZoneKey(screenId: screen1, index: 1), "lowestIndexEmptyZone should pick the globally lowest index regardless of the preferred screen (got \(String(describing: global)))")
            let sameScreen = manager.lowestIndexEmptyZoneOnSameScreen(screenId: screen2)
            assert(sameScreen == ZoneKey(screenId: screen2, index: 2), "lowestIndexEmptyZoneOnSameScreen should stay on the requested screen (got \(String(describing: sameScreen)))")

            let excluded = manager.lowestIndexEmptyZone(excluding: expectedPreferred)
            let expectedExcluded = ZoneKey(screenId: screen1, index: 1)
            assert(excluded == expectedExcluded, "lowestIndexEmptyZone should exclude the provided zone key (got \(String(describing: excluded)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 7001, toZoneIndex: 1)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 99), reason: "test")
            assert(manager.targetedFloatingScreenId == screen1, "setTargetedZone should repair invalid zone to floating when no empty zones exist (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 3],
                screenOrder: [screen1]
            )

            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 7002, toZoneIndex: 1)

            manager.setFloatingTarget(on: screen1, reason: "test")
            manager.targetAfterCreatingZone(on: screen1, reason: "zone-added")
            let expected = ZoneKey(screenId: screen1, index: 2)
            assert(manager.targetedZoneKey == expected, "targetAfterCreatingZone should target the lowest-index empty tiling zone on the same screen (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 3],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 701, toZoneIndex: 1)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 1), reason: "test")
            manager.retargetAfterFillingZone(ZoneKey(screenId: screen1, index: 1), reason: "filled")

            let expected = ZoneKey(screenId: screen1, index: 2)
            assert(manager.targetedZoneKey == expected, "retargetAfterFillingZone should select next empty zone on same screen (got \(String(describing: manager.targetedZoneKey)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 7101, toZoneIndex: 1)
            controller.assignWindow(windowId: 7102, toZoneIndex: 2)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 2), reason: "test")
            _ = controller.removeZone(at: 2)
            manager.ensureTargetedZone(reason: "repair")

            assert(manager.targetedFloatingScreenId == screen1, "ensureTargetedZone should repair to floating when no empty tiling zones exist (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 801, toZoneIndex: 1)
            controller.assignWindow(windowId: 802, toZoneIndex: 2)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 2), reason: "test")
            manager.retargetAfterFillingZone(ZoneKey(screenId: screen1, index: 2), reason: "filled")

            assert(manager.targetedFloatingScreenId == screen1, "retargetAfterFillingZone should target floating zone when no empty zones remain")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2, screen2: 2],
                screenOrder: [screen1, screen2]
            )
            let controller1 = delegate.zoneController(for: screen1)!
            let controller2 = delegate.zoneController(for: screen2)!

            controller1.assignWindow(windowId: 901, toZoneIndex: 1)
            controller1.assignWindow(windowId: 902, toZoneIndex: 2)
            controller2.assignWindow(windowId: 903, toZoneIndex: 2)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 2), reason: "test")
            manager.retargetAfterFillingZone(ZoneKey(screenId: screen1, index: 2), reason: "filled")

            let expected = ZoneKey(screenId: screen2, index: 1)
            assert(manager.targetedZoneKey == expected, "retargetAfterFillingZone should prefer empty tiling zone on another screen before floating zone (got \(String(describing: manager.targetedZoneKey)))")
        }

        do {
            let screen3: CGDirectDisplayID = 3
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1, screen3: 1],
                screenOrder: [screen1, screen2, screen3]
            )
            let controller3 = delegate.zoneController(for: screen3)!
            controller3.assignWindow(windowId: 1001, toZoneIndex: 1)

            manager.setTargetedZone(ZoneKey(screenId: screen3, index: 1), reason: "test")
            manager.retargetAfterFillingZone(ZoneKey(screenId: screen3, index: 1), reason: "filled")

            let expected = ZoneKey(screenId: screen1, index: 1)
            assert(manager.targetedZoneKey == expected, "retargetAfterFillingZone should break ties between screens by screen index (got \(String(describing: manager.targetedZoneKey)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 1201, toZoneIndex: 1)

            manager.setFloatingTarget(on: screen1, reason: "test")
            manager.retargetAfterFillingFloatingZone(on: screen1, reason: "filled")

            let expected = ZoneKey(screenId: screen1, index: 2)
            assert(manager.targetedZoneKey == expected, "retargetAfterFillingFloatingZone should select an empty tiling zone on the same screen (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )
            let controller1 = delegate.zoneController(for: screen1)!
            controller1.assignWindow(windowId: 1202, toZoneIndex: 1)

            manager.setFloatingTarget(on: screen1, reason: "test")
            manager.retargetAfterFillingFloatingZone(on: screen1, reason: "filled")

            let expected = ZoneKey(screenId: screen2, index: 1)
            assert(manager.targetedZoneKey == expected, "retargetAfterFillingFloatingZone should fall back to an empty tiling zone on another screen (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )
            let controller1 = delegate.zoneController(for: screen1)!
            let controller2 = delegate.zoneController(for: screen2)!
            controller1.assignWindow(windowId: 1203, toZoneIndex: 1)
            controller2.assignWindow(windowId: 1204, toZoneIndex: 1)

            manager.setFloatingTarget(on: screen1, reason: "test", explicit: true)
            manager.retargetAfterFillingFloatingZone(on: screen1, reason: "filled")

            assert(manager.targetedFloatingScreenId == screen1 && !manager.isFloatingTargetExplicit, "filling a floating zone with no empty tiling zone left should keep it targeted, implicitly (got \(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )
            let controller1 = delegate.zoneController(for: screen1)!
            let controller2 = delegate.zoneController(for: screen2)!
            controller1.assignWindow(windowId: 1205, toZoneIndex: 1)
            controller2.assignWindow(windowId: 1206, toZoneIndex: 1)

            manager.setFloatingTarget(on: screen2, reason: "test")
            delegate.fullScreenDisplayIds = [screen2]
            manager.retargetAfterFillingFloatingZone(on: screen2, reason: "filled")

            assert(manager.targetedFloatingScreenId == screen1, "a floating fill on a screen paused for full screen should fall back to the first floating zone in screen order (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )
            let controller1 = delegate.zoneController(for: screen1)!
            let controller2 = delegate.zoneController(for: screen2)!
            controller1.assignWindow(windowId: 1209, toZoneIndex: 1)
            controller2.assignWindow(windowId: 1210, toZoneIndex: 1)

            manager.setTargetedZone(ZoneKey(screenId: screen2, index: 1), reason: "test")
            manager.retargetAfterFillingZone(ZoneKey(screenId: screen2, index: 1), reason: "filled")

            assert(manager.targetedFloatingScreenId == screen2, "retargetAfterFillingZone should fall to the just-filled screen's floating zone, not the first in screen order (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 3],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 1301, toZoneIndex: 3)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 2), reason: "test")
            manager.retargetAfterMovingWindow(
                from: .tiled(ZoneKey(screenId: screen1, index: 2)),
                to: .tiled(ZoneKey(screenId: screen1, index: 3)),
                preMoveTarget: .tiled(ZoneKey(screenId: screen1, index: 2)),
                reason: "moved"
            )

            let expected = ZoneKey(screenId: screen1, index: 1)
            assert(manager.targetedZoneKey == expected, "a move out of the targeted zone should retarget as if the destination was just filled, per the fill priority rather than back to the vacated zone (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 1302, toZoneIndex: 2)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 2), reason: "test")
            manager.retargetAfterMovingWindow(
                from: .floating(screenId: screen1),
                to: .tiled(ZoneKey(screenId: screen1, index: 2)),
                preMoveTarget: .tiled(ZoneKey(screenId: screen1, index: 2)),
                reason: "moved"
            )

            let expected = ZoneKey(screenId: screen1, index: 1)
            assert(manager.targetedZoneKey == expected, "a move into the targeted zone should retarget as if it was just filled (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 3],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 1303, toZoneIndex: 2)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 3), reason: "test")
            manager.retargetAfterMovingWindow(
                from: .tiled(ZoneKey(screenId: screen1, index: 1)),
                to: .tiled(ZoneKey(screenId: screen1, index: 2)),
                preMoveTarget: .tiled(ZoneKey(screenId: screen1, index: 3)),
                reason: "moved"
            )

            let expected = ZoneKey(screenId: screen1, index: 3)
            assert(manager.targetedZoneKey == expected, "a move not touching the target should leave the uninvolved target alone (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 1304, toZoneIndex: 1)

            manager.setFloatingTarget(on: screen1, reason: "test")
            manager.retargetAfterMovingWindow(
                from: .floating(screenId: screen1),
                to: .floating(screenId: screen1),
                preMoveTarget: .floating(screenId: screen1),
                reason: "moved"
            )

            assert(manager.targetedFloatingScreenId == screen1, "a reposition within the same zone is not a move and should not retarget (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 1401, toZoneIndex: 2)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 2), reason: "test")
            manager.retargetAfterMovingWindow(
                from: nil,
                to: .tiled(ZoneKey(screenId: screen1, index: 2)),
                preMoveTarget: .tiled(ZoneKey(screenId: screen1, index: 2)),
                reason: "moved"
            )

            let expected = ZoneKey(screenId: screen1, index: 1)
            assert(manager.targetedZoneKey == expected, "a sourceless move into the targeted zone should retarget as a fill (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 3],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 1402, toZoneIndex: 2)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 3), reason: "test")
            manager.retargetAfterMovingWindow(
                from: nil,
                to: .tiled(ZoneKey(screenId: screen1, index: 2)),
                preMoveTarget: .tiled(ZoneKey(screenId: screen1, index: 3)),
                reason: "moved"
            )

            let expected = ZoneKey(screenId: screen1, index: 3)
            assert(manager.targetedZoneKey == expected, "a sourceless move into a non-targeted zone should leave the uninvolved target alone (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 1403, toZoneIndex: 2)

            manager.setTargetedZone(nil, reason: "test")
            manager.retargetAfterMovingWindow(
                from: .tiled(ZoneKey(screenId: screen1, index: 1)),
                to: .tiled(ZoneKey(screenId: screen1, index: 2)),
                preMoveTarget: nil,
                reason: "moved"
            )

            assert(manager.targetedDestination == nil, "with no pre-move target, a move should retarget nothing (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 2],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 1404, toZoneIndex: 2)

            manager.setFloatingTarget(on: screen1, reason: "test")
            manager.retargetAfterMovingWindow(
                from: .floating(screenId: screen1),
                to: .tiled(ZoneKey(screenId: screen1, index: 2)),
                preMoveTarget: .floating(screenId: screen1),
                reason: "moved"
            )

            let expected = ZoneKey(screenId: screen1, index: 1)
            assert(manager.targetedZoneKey == expected, "a promotion out of the targeted floating zone should retarget as if the destination was just filled (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 3],
                screenOrder: [screen1]
            )
            let controller = delegate.zoneController(for: screen1)!
            // Occupancy as it stands after a swap settles: the destination holds the moved
            // window and the origin holds the swap partner, so only the floating zone is free.
            controller.assignWindow(windowId: 1405, toZoneIndex: 1)
            controller.assignWindow(windowId: 1406, toZoneIndex: 3)
            controller.assignWindow(windowId: 1407, toZoneIndex: 2)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 2), reason: "test")
            manager.retargetAfterMovingWindow(
                from: .tiled(ZoneKey(screenId: screen1, index: 2)),
                to: .tiled(ZoneKey(screenId: screen1, index: 3)),
                preMoveTarget: .tiled(ZoneKey(screenId: screen1, index: 2)),
                reason: "moved"
            )

            assert(manager.targetedFloatingScreenId == screen1, "a swap move should evaluate after the partner settles: the refilled origin is not a candidate (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )
            delegate.fullScreenDisplayIds = [screen1]

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 1), reason: "test")
            let expected = ZoneKey(screenId: screen2, index: 1)
            assert(manager.targetedZoneKey == expected, "setTargetedZone should skip full-screen screens when selecting a target (got \(String(describing: manager.targetedZoneKey)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )
            delegate.fullScreenDisplayIds = [screen1, screen2]

            manager.setTargetedZone(ZoneKey(screenId: screen2, index: 1), reason: "test")
            let expected = ZoneKey(screenId: screen1, index: 1)
            assert(manager.targetedZoneKey == expected, "when all screens are full-screen, targeting should fall back to screen 0 (got \(String(describing: manager.targetedZoneKey)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )
            let controller1 = delegate.zoneController(for: screen1)!
            let controller2 = delegate.zoneController(for: screen2)!
            controller1.assignWindow(windowId: 1101, toZoneIndex: 1)
            controller2.assignWindow(windowId: 1102, toZoneIndex: 1)

            delegate.fullScreenDisplayIds = [screen1, screen2]

            manager.setTargetedZone(ZoneKey(screenId: screen2, index: 1), reason: "test")
            assert(manager.targetedFloatingScreenId == screen1, "when all screens are full-screen and no empty zones remain, target floating zone on screen 0 (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )

            let controller1 = delegate.zoneController(for: screen1)!
            let controller2 = delegate.zoneController(for: screen2)!
            controller1.assignWindow(windowId: 1501, toZoneIndex: 1)
            controller2.assignWindow(windowId: 1502, toZoneIndex: 1)

            // An implicit floating target follows the frontmost window's display...
            manager.setFloatingTarget(on: screen1, reason: "test")
            manager.followFrontmostWindow(of: 1, onDisplay: screen2, pointerScreenId: nil, reason: "frontmost")
            assert(manager.targetedFloatingScreenId == screen2 && !manager.isFloatingTargetExplicit, "an implicit floating target should follow the frontmost window's display (got \(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit))")

            // ...and an explicit one ignores the frontmost window altogether.
            manager.setFloatingTarget(on: screen1, reason: "test", explicit: true)
            manager.followFrontmostWindow(of: 1, onDisplay: screen2, pointerScreenId: nil, reason: "frontmost")
            assert(manager.targetedFloatingScreenId == screen1 && manager.isFloatingTargetExplicit, "an explicit floating target should not follow the frontmost window (got \(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit))")

            // Any retarget demotes an explicit target, even one landing on the same zone: with every
            // zone occupied, filling screen 1's floating zone retargets right back to it, implicitly.
            manager.retargetAfterFillingFloatingZone(on: screen1, reason: "filled")
            assert(manager.targetedFloatingScreenId == screen1 && !manager.isFloatingTargetExplicit, "a retarget landing on the explicitly targeted floating zone should still make it implicit (got \(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit))")

            // Re-selecting the targeted floating zone explicitly changes only how it is targeted.
            let refreshCountBefore = delegate.refreshCount
            manager.markFloatingTargetExplicit(reason: "launcher-shown")
            assert(manager.targetedFloatingScreenId == screen1 && manager.isFloatingTargetExplicit && delegate.refreshCount == refreshCountBefore + 1, "marking the targeted floating zone explicit should keep the destination and refresh the indicators once (got \(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit), refreshes: \(delegate.refreshCount - refreshCountBefore))")

            // Marking it implicit again undoes that alone, so it follows the frontmost window once more.
            manager.markFloatingTargetImplicit(reason: "launcher-cancelled")
            manager.followFrontmostWindow(of: 1, onDisplay: screen2, pointerScreenId: nil, reason: "frontmost")
            assert(manager.targetedFloatingScreenId == screen2 && !manager.isFloatingTargetExplicit, "marking the targeted floating zone implicit should let it follow the frontmost window again (got \(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit))")

            // While the Launcher is shown, a floating target it re-anchors to is explicit even when the
            // rule setting it would make it implicit, including a same-zone retarget (which fires no
            // change callback).
            delegate.isLauncherVisible = true
            manager.setFloatingTarget(on: screen1, reason: "shortcut-retarget-open-launcher")
            assert(manager.targetedFloatingScreenId == screen1 && manager.isFloatingTargetExplicit, "a floating target set under a shown Launcher should be explicit (got \(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit))")
            manager.retargetAfterFillingFloatingZone(on: screen1, reason: "filled")
            assert(manager.targetedFloatingScreenId == screen1 && manager.isFloatingTargetExplicit, "a same-zone retarget under a shown Launcher should keep the floating target explicit (got \(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit))")
            delegate.isLauncherVisible = false

            // A tiling target is neither explicit nor moved by the frontmost window, and marking it
            // implicit is a no-op.
            let tiled = ZoneKey(screenId: screen1, index: 1)
            manager.setTargetedZone(tiled, reason: "test")
            manager.markFloatingTargetImplicit(reason: "test")
            manager.followFrontmostWindow(of: 1, onDisplay: screen2, pointerScreenId: nil, reason: "frontmost")
            assert(manager.targetedZoneKey == tiled && !manager.isFloatingTargetExplicit, "a tiling target should never be explicit or follow the frontmost window (got \(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 1, screen2: 1],
                screenOrder: [screen1, screen2]
            )
            delegate.zoneController(for: screen1)!.assignWindow(windowId: 1601, toZoneIndex: 1)
            delegate.zoneController(for: screen2)!.assignWindow(windowId: 1602, toZoneIndex: 1)
            let appA: pid_t = 100
            let appB: pid_t = 200

            // Each case starts with the implicit floating target on screen 1 following a window of
            // application A to screen 2 at time 10, with the pointer on screen 1 unless stated.
            func followAToScreen2(pointerOnScreen2: Bool = false) {
                manager.setFloatingTarget(on: screen1, reason: "test")
                manager.followFrontmostWindow(
                    of: appA,
                    onDisplay: screen2,
                    pointerScreenId: pointerOnScreen2 ? screen2 : screen1,
                    reason: "frontmost",
                    startedAt: 10
                )
            }
            let undoInterval: TimeInterval = 3
            func undo(_ pid: pid_t, lastPress: TimeInterval = 60, at now: TimeInterval = 11) -> Bool {
                manager.undoFollow(forWindowOf: pid, within: undoInterval, secondsSinceLastPress: lastPress, now: now)
            }
            func target() -> String {
                "\(String(describing: manager.targetedDestination)), explicit: \(manager.isFloatingTargetExplicit)"
            }

            // A window of the followed application arriving soon after, with no press since the
            // follow, returns the target to the display it left, once.
            followAToScreen2()
            assert(undo(appA) && manager.targetedFloatingScreenId == screen1 && !manager.isFloatingTargetExplicit, "a window of the followed application arriving soon after should undo the follow (got \(target()))")
            assert(!undo(appA, at: 11.5) && manager.targetedFloatingScreenId == screen1, "a follow should be undone only once (got \(target()))")

            // Only the next window placed can undo the follow: another application's window placed
            // first leaves the target where it is, and so does the followed application's after it.
            followAToScreen2()
            assert(!undo(appB) && manager.targetedFloatingScreenId == screen2, "another application's window should not undo the follow (got \(target()))")
            assert(!undo(appA) && manager.targetedFloatingScreenId == screen2, "the followed application's window placed after another application's should not undo the follow (got \(target()))")

            // Each of these keeps the follow: a key or mouse press since it, an arrival after the undo
            // interval, the pointer on the new display as the target moved, any other change of the
            // target since, and a display left behind that can no longer be targeted.
            followAToScreen2()
            assert(!undo(appA, lastPress: 0.5) && manager.targetedFloatingScreenId == screen2, "a press since the follow should keep it (got \(target()))")
            followAToScreen2()
            assert(!undo(appA, at: 10 + undoInterval + 0.1) && manager.targetedFloatingScreenId == screen2, "an arrival after the undo interval should keep the follow (got \(target()))")
            followAToScreen2(pointerOnScreen2: true)
            assert(!undo(appA) && manager.targetedFloatingScreenId == screen2, "a follow made with the pointer on the new display should not be undoable (got \(target()))")
            followAToScreen2()
            manager.markFloatingTargetExplicit(reason: "launcher-shown")
            manager.markFloatingTargetImplicit(reason: "launcher-cancelled")
            assert(!undo(appA) && manager.targetedFloatingScreenId == screen2, "another change of the target should drop the follow (got \(target()))")
            followAToScreen2()
            delegate.fullScreenDisplayIds = [screen1]
            assert(!undo(appA) && manager.targetedFloatingScreenId == screen2, "a follow should not be undone to a display paused for full screen (got \(target()))")
            delegate.fullScreenDisplayIds = []
        }

        if allPassed {
            print("TargetedZoneManagerTests: all tests passed")
        }
        return allPassed
    }

    private static func makeEnvironment(
        zoneCounts: [CGDirectDisplayID: Int],
        screenOrder: [CGDirectDisplayID]
    ) -> (TargetedZoneManager, MockTargetedZoneDelegate) {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        var contexts: [CGDirectDisplayID: ScreenContext] = [:]

        for (screenId, count) in zoneCounts {
            let descriptor = makeDescriptor(displayId: screenId, primaryBounds: frame)
            let controller = ZoneController(screenFrame: frame, initialZoneCount: count, layoutStyle: .rightBar)
            contexts[screenId] = ScreenContext(descriptor: descriptor, zoneController: controller)
        }

        let delegate = MockTargetedZoneDelegate(
            screenContexts: contexts,
            screenOrder: screenOrder,
            primaryScreenId: screenOrder.first ?? 0
        )

        let manager = TargetedZoneManager()
        manager.delegate = delegate
        if let primary = screenOrder.first {
            manager.initialize(primaryScreenId: primary)
        }
        return (manager, delegate)
    }

    private final class MockTargetedZoneDelegate: TargetedZoneManagerDelegate {
        var screenContexts: [CGDirectDisplayID: ScreenContext]
        var screenOrder: [CGDirectDisplayID]
        var primaryScreenId: CGDirectDisplayID
        var fullScreenDisplayIds: Set<CGDirectDisplayID>
        var isLauncherVisible = false
        var refreshCount = 0

        init(
            screenContexts: [CGDirectDisplayID: ScreenContext],
            screenOrder: [CGDirectDisplayID],
            primaryScreenId: CGDirectDisplayID,
            fullScreenDisplayIds: Set<CGDirectDisplayID> = []
        ) {
            self.screenContexts = screenContexts
            self.screenOrder = screenOrder
            self.primaryScreenId = primaryScreenId
            self.fullScreenDisplayIds = fullScreenDisplayIds
        }

        func zoneController(for screenId: CGDirectDisplayID) -> ZoneController? {
            screenContexts[screenId]?.zoneController
        }

        func refreshIndicators() {
            refreshCount += 1
        }

        func targetedZoneDidChange(from oldDestination: TargetedZoneManager.TargetedDestination?, to newDestination: TargetedZoneManager.TargetedDestination?) {
            // No-op for tests
        }
    }

    private static func makeDescriptor(displayId: CGDirectDisplayID, primaryBounds: CGRect) -> ScreenDescriptor {
        ScreenDescriptor(
            displayId: displayId,
            localizedName: "Display \(displayId)",
            cocoaBounds: primaryBounds,
            visibleCocoaBounds: primaryBounds,
            primaryBounds: primaryBounds
        )
    }
}
