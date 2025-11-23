import Foundation
import ApplicationServices

/// Aggregates lightweight runtime tests that can be triggered via the `--self-test` flag
enum GuardrailTests {
    @discardableResult
    static func runAll() -> Bool {
        var allPassed = true

        if !ZoneLayoutTests.run() {
            allPassed = false
        }
        if !TargetedZoneSelectionTests.run() {
            allPassed = false
        }
        if !AccessibilityNotificationCatalogTests.run() {
            allPassed = false
        }
        if !ActiveFitPolicyTests.run() {
            allPassed = false
        }

        if allPassed {
            print("GuardrailTests: all tests passed")
        } else {
            print("GuardrailTests: failures detected")
        }
        return allPassed
    }
}

private enum TargetedZoneSelectionTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("TargetedZoneSelectionTests: \(message)")
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

        if allPassed {
            print("TargetedZoneSelectionTests: all tests passed")
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

private enum ActiveFitPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ActiveFitPolicyTests: \(message)")
                allPassed = false
            }
        }

        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let tolerance: CGFloat = 1.0

        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 2,
            zoneOrigin: CGPoint(x: 1300, y: 0),
            windowSize: CGSize(width: 800, height: 900),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.x == 1120, "right overflow should shift origin left by overflow amount (expected 1120, got \(frame.origin.x))")
            assert(frame.origin.y == 0, "pure horizontal overflow should not shift vertically")
        } else {
            assert(false, "expected ActiveFit to translate horizontally for oversized width in zone 2")
        }

        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 3,
            zoneOrigin: CGPoint(x: 1280, y: 640),
            windowSize: CGSize(width: 900, height: 520),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.x == 1020, "combined overflow should shift left as needed (expected 1020, got \(frame.origin.x))")
            assert(frame.origin.y == 560, "combined overflow should shift up as needed (expected 560, got \(frame.origin.y))")
        } else {
            assert(false, "expected ActiveFit to translate for combined width/height overflow in zone 3")
        }

        let noOverflow = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 2,
            zoneOrigin: CGPoint(x: 960, y: 0),
            windowSize: CGSize(width: 400, height: 500),
            screenBounds: bounds,
            tolerance: tolerance
        )
        assert(noOverflow == nil, "ActiveFit should not trigger when the frame already fits")

        let zoneOne = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 1,
            zoneOrigin: CGPoint(x: 0, y: 0),
            windowSize: CGSize(width: 2000, height: 1100),
            screenBounds: bounds,
            tolerance: tolerance
        )
        assert(zoneOne == nil, "ActiveFit should ignore zone 1 even if it would overflow")

        let tinyOverflow = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 2,
            zoneOrigin: CGPoint(x: 1000, y: 0),
            windowSize: CGSize(width: 920.2, height: 400),
            screenBounds: bounds,
            tolerance: tolerance
        )
        assert(tinyOverflow == nil, "ActiveFit should ignore sub-tolerance overflow")

        if allPassed {
            print("ActiveFitPolicyTests: all tests passed")
        }
        return allPassed
    }
}

private enum AccessibilityNotificationCatalogTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: Bool, _ message: String) {
            if !condition {
                print("AccessibilityNotificationCatalogTests: \(message)")
                allPassed = false
            }
        }

        let windowNames = Set(AccessibilityNotificationCatalog.windowNotifications.map { $0 as String })
        let expectedWindowNames: Set<String> = [
            kAXUIElementDestroyedNotification as String,
            kAXWindowMiniaturizedNotification as String,
            kAXWindowDeminiaturizedNotification as String,
            kAXMovedNotification as String,
            kAXResizedNotification as String
        ]
        assert(windowNames == expectedWindowNames, "window notifications should match expected set")

        let applicationNames = Set(AccessibilityNotificationCatalog.applicationNotifications.map { $0 as String })
        let expectedApplicationNames: Set<String> = [
            kAXWindowCreatedNotification as String,
            kAXFocusedWindowChangedNotification as String,
            kAXMainWindowChangedNotification as String,
            kAXUIElementDestroyedNotification as String
        ]
        assert(applicationNames == expectedApplicationNames, "application notifications should match expected set")

        if allPassed {
            print("AccessibilityNotificationCatalogTests: all tests passed")
        }
        return allPassed
    }
}
