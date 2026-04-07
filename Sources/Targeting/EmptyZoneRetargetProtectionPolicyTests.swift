import Foundation
import CoreGraphics

/// Guardrail tests for empty-zone retarget protection policy.
enum EmptyZoneRetargetProtectionPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("EmptyZoneRetargetProtectionPolicyTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let zone1Key = ZoneKey(screenId: screen1, index: 1)
        let zone2Key = ZoneKey(screenId: screen1, index: 2)
        let zone2 = TargetedZoneManager.TargetedDestination.tiled(zone2Key)
        let chromePid: pid_t = 100
        let safariPid: pid_t = 200
        let fallbackWindowId = 11
        let otherChromeWindowId = 12
        let now = Date()
        let futureDeadline = now.addingTimeInterval(0.5)
        let expiredDeadline = now.addingTimeInterval(-0.1)

        // Core case: the expected same-app sibling focus fallback after close/minimize should be suppressed.
        do {
            let result = EmptyZoneRetargetProtectionPolicy.shouldSuppressRetarget(
                protectedZone: zone2Key,
                protectedPid: chromePid,
                protectedWindowId: fallbackWindowId,
                currentTarget: zone2,
                incomingPid: chromePid,
                incomingWindowId: fallbackWindowId,
                deadline: futureDeadline,
                now: now
            )
            assert(result, "should suppress the protected same-app fallback window while protected zone is still targeted")
        }

        // A different same-app window should NOT be suppressed; switching to it should retarget.
        do {
            let result = EmptyZoneRetargetProtectionPolicy.shouldSuppressRetarget(
                protectedZone: zone2Key,
                protectedPid: chromePid,
                protectedWindowId: fallbackWindowId,
                currentTarget: zone2,
                incomingPid: chromePid,
                incomingWindowId: otherChromeWindowId,
                deadline: futureDeadline,
                now: now
            )
            assert(!result, "should not suppress a different same-app window")
        }

        // Cross-app focus change should NOT be suppressed.
        do {
            let result = EmptyZoneRetargetProtectionPolicy.shouldSuppressRetarget(
                protectedZone: zone2Key,
                protectedPid: chromePid,
                protectedWindowId: fallbackWindowId,
                currentTarget: zone2,
                incomingPid: safariPid,
                incomingWindowId: fallbackWindowId,
                deadline: futureDeadline,
                now: now
            )
            assert(!result, "should not suppress cross-app retarget")
        }

        // Expired deadline should NOT suppress.
        do {
            let result = EmptyZoneRetargetProtectionPolicy.shouldSuppressRetarget(
                protectedZone: zone2Key,
                protectedPid: chromePid,
                protectedWindowId: fallbackWindowId,
                currentTarget: zone2,
                incomingPid: chromePid,
                incomingWindowId: fallbackWindowId,
                deadline: expiredDeadline,
                now: now
            )
            assert(!result, "should not suppress after deadline expires")
        }

        // Target changed away from protected zone should NOT suppress.
        do {
            let zone1 = TargetedZoneManager.TargetedDestination.tiled(zone1Key)
            let result = EmptyZoneRetargetProtectionPolicy.shouldSuppressRetarget(
                protectedZone: zone2Key,
                protectedPid: chromePid,
                protectedWindowId: fallbackWindowId,
                currentTarget: zone1,
                incomingPid: chromePid,
                incomingWindowId: fallbackWindowId,
                deadline: futureDeadline,
                now: now
            )
            assert(!result, "should not suppress when target has moved away from protected zone")
        }

        // Floating target should NOT match protected tiled zone.
        do {
            let floating = TargetedZoneManager.TargetedDestination.floating(screenId: screen1)
            let result = EmptyZoneRetargetProtectionPolicy.shouldSuppressRetarget(
                protectedZone: zone2Key,
                protectedPid: chromePid,
                protectedWindowId: fallbackWindowId,
                currentTarget: floating,
                incomingPid: chromePid,
                incomingWindowId: fallbackWindowId,
                deadline: futureDeadline,
                now: now
            )
            assert(!result, "should not suppress when current target is floating")
        }

        // Nil target should NOT suppress.
        do {
            let result = EmptyZoneRetargetProtectionPolicy.shouldSuppressRetarget(
                protectedZone: zone2Key,
                protectedPid: chromePid,
                protectedWindowId: fallbackWindowId,
                currentTarget: nil,
                incomingPid: chromePid,
                incomingWindowId: fallbackWindowId,
                deadline: futureDeadline,
                now: now
            )
            assert(!result, "should not suppress when current target is nil")
        }

        return allPassed
    }
}
