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
        if !PlaceholderResizePolicyTests.run() {
            allPassed = false
        }
        if !AccessibilityNotificationCatalogTests.run() {
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

private enum PlaceholderResizePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: Bool, _ message: String) {
            if !condition {
                print("PlaceholderResizePolicyTests: \(message)")
                allPassed = false
            }
        }

        assert(
            PlaceholderResizePolicy.allowedAxes(zoneIndex: 1, zoneCount: 1, zoneIsEmpty: true).isEmpty,
            "single zone should not allow resizing"
        )
        assert(
            PlaceholderResizePolicy.allowedAxes(zoneIndex: 1, zoneCount: 2, zoneIsEmpty: true) == [.horizontal],
            "two zones should allow horizontal resizing"
        )
        assert(
            PlaceholderResizePolicy.allowedAxes(zoneIndex: 1, zoneCount: 3, zoneIsEmpty: true) == [.horizontal],
            "left zone in three-zone layout should allow horizontal resizing only"
        )
        assert(
            PlaceholderResizePolicy.allowedAxes(zoneIndex: 2, zoneCount: 3, zoneIsEmpty: true) == [.horizontal, .vertical],
            "top-right zone in three-zone layout should allow horizontal and vertical resizing"
        )
        assert(
            PlaceholderResizePolicy.allowedAxes(zoneIndex: 3, zoneCount: 3, zoneIsEmpty: true) == [.horizontal, .vertical],
            "bottom-right zone in three-zone layout should allow horizontal and vertical resizing"
        )
        assert(
            PlaceholderResizePolicy.allowedAxes(zoneIndex: 1, zoneCount: 2, zoneIsEmpty: false).isEmpty,
            "occupied zones should not be resizable"
        )

        if allPassed {
            print("PlaceholderResizePolicyTests: all tests passed")
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
