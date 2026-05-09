/// Guardrail tests for FloatingZoneEmptyRetargetPolicy.
import Foundation
import CoreGraphics

enum FloatingZoneEmptyRetargetPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("FloatingZoneEmptyRetargetPolicyTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2

        // Floating-on-screen-2 targeted; floating-on-screen-1 emptied → retarget to screen 1.
        do {
            let result = FloatingZoneEmptyRetargetPolicy.retargetScreenId(
                emptiedScreenId: screen1,
                currentTarget: .floating(screenId: screen2)
            )
            assert(result == screen1, "should retarget to emptied floating zone when target is another floating zone (got \(String(describing: result)))")
        }

        // Tiling target → keep (floating is weaker, never steals from tiling).
        do {
            let result = FloatingZoneEmptyRetargetPolicy.retargetScreenId(
                emptiedScreenId: screen1,
                currentTarget: .tiled(ZoneKey(screenId: screen2, index: 1))
            )
            assert(result == nil, "should not retarget when current target is a tiling zone (got \(String(describing: result)))")
        }

        // Same-screen tiling target → also keep.
        do {
            let result = FloatingZoneEmptyRetargetPolicy.retargetScreenId(
                emptiedScreenId: screen1,
                currentTarget: .tiled(ZoneKey(screenId: screen1, index: 1))
            )
            assert(result == nil, "should not retarget when current target is a tiling zone on the same screen (got \(String(describing: result)))")
        }

        // Same floating zone already targeted → keep (existing rule covers it).
        do {
            let result = FloatingZoneEmptyRetargetPolicy.retargetScreenId(
                emptiedScreenId: screen1,
                currentTarget: .floating(screenId: screen1)
            )
            assert(result == nil, "should not change target when the emptied floating zone is already targeted (got \(String(describing: result)))")
        }

        // No current target → no retargeting.
        do {
            let result = FloatingZoneEmptyRetargetPolicy.retargetScreenId(
                emptiedScreenId: screen1,
                currentTarget: nil
            )
            assert(result == nil, "should not retarget when there is no current target (got \(String(describing: result)))")
        }

        if allPassed {
            print("FloatingZoneEmptyRetargetPolicyTests: all tests passed")
        }
        return allPassed
    }
}
