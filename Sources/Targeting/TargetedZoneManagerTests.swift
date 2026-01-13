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
                zoneCounts: [screen1: 3, screen2: 2],
                screenOrder: [screen1, screen2]
            )
            let controller1 = delegate.zoneController(for: screen1)!
            let controller2 = delegate.zoneController(for: screen2)!

            controller1.assignWindow(windowId: 101, toZoneIndex: 1)
            controller1.assignWindow(windowId: 102, toZoneIndex: 3)
            controller2.assignWindow(windowId: 201, toZoneIndex: 2)

            let expected = ZoneKey(screenId: screen2, index: 1)
            let actual = manager.fallbackTargetedZone(preferredScreenId: nil)
            assert(actual == expected, "fallback should pick lowest-index empty zone across screens (got \(String(describing: actual)))")
        }

        do {
            let (manager, delegate) = makeEnvironment(
                zoneCounts: [screen1: 3, screen2: 2],
                screenOrder: [screen1, screen2]
            )
            let controller1 = delegate.zoneController(for: screen1)!
            let controller2 = delegate.zoneController(for: screen2)!

            for index in 1...3 {
                controller1.assignWindow(windowId: 300 + index, toZoneIndex: index)
            }
            for index in 1...2 {
                controller2.assignWindow(windowId: 400 + index, toZoneIndex: index)
            }

            let expected = ZoneKey(screenId: screen1, index: 3)
            let actual = manager.fallbackTargetedZone(preferredScreenId: nil)
            assert(actual == expected, "fallback should pick highest-index occupied zone when no empties remain (got \(String(describing: actual)))")
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
                zoneCounts: [screen1: 2],
                screenOrder: [screen1]
            )

            withExtendedLifetime(delegate) {
                manager.setTargetedZone(ZoneKey(screenId: screen1, index: 99), reason: "test")
                manager.ensureTargetedZone(reason: "repair")
            }

            let targeted = manager.targetedZoneKey
            assert(targeted == ZoneKey(screenId: screen1, index: 1), "ensureTargetedZone should repair invalid zone to a valid fallback (got \(String(describing: targeted)))")
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
            controller.assignWindow(windowId: 801, toZoneIndex: 1)
            controller.assignWindow(windowId: 802, toZoneIndex: 2)

            manager.setTargetedZone(ZoneKey(screenId: screen1, index: 2), reason: "test")
            manager.retargetAfterFillingZone(ZoneKey(screenId: screen1, index: 2), reason: "filled")

            assert(manager.targetedTemporaryScreenId == screen1, "retargetAfterFillingZone should target temporary zone when no empty zones remain")
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
        var refreshCount = 0

        init(
            screenContexts: [CGDirectDisplayID: ScreenContext],
            screenOrder: [CGDirectDisplayID],
            primaryScreenId: CGDirectDisplayID
        ) {
            self.screenContexts = screenContexts
            self.screenOrder = screenOrder
            self.primaryScreenId = primaryScreenId
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
