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
            assert(manager.targetedTemporaryScreenId == screen1, "setTargetedZone should repair invalid zone to temporary when no empty zones exist (got \(String(describing: manager.targetedDestination)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 3],
                screenOrder: [screen1]
            )

            let controller = delegate.zoneController(for: screen1)!
            controller.assignWindow(windowId: 7002, toZoneIndex: 1)

            manager.setTemporaryTarget(on: screen1, reason: "test")
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

            assert(manager.targetedTemporaryScreenId == screen1, "ensureTargetedZone should repair to temporary when no empty tiling zones exist (got \(String(describing: manager.targetedDestination)))")
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

            assert(manager.targetedTemporaryScreenId == screen1, "retargetAfterFillingZone should target temporary zone when no empty zones remain")
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
            assert(manager.targetedZoneKey == expected, "retargetAfterFillingZone should prefer empty tiling zone on another screen before temporary zone (got \(String(describing: manager.targetedZoneKey)))")
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
            assert(manager.targetedTemporaryScreenId == screen1, "when all screens are full-screen and no empty zones remain, target temporary zone on screen 0 (got \(String(describing: manager.targetedDestination)))")
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
            let controller = ZoneController(screenFrame: frame, initialZoneCount: count)
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
