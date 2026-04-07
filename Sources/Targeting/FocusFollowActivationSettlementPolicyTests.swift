import Foundation
import CoreGraphics

/// Guardrail tests for follows-focus activation settlement policy.
enum FocusFollowActivationSettlementPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("FocusFollowActivationSettlementPolicyTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2
        let zone1 = TargetedZoneManager.TargetedDestination.tiled(ZoneKey(screenId: screen1, index: 1))
        let zone2 = TargetedZoneManager.TargetedDestination.tiled(ZoneKey(screenId: screen1, index: 2))
        let floating = TargetedZoneManager.TargetedDestination.floating(screenId: screen2)

        do {
            let result = FocusFollowActivationSettlementPolicy.shouldDeferImmediateRetarget(
                targetingMode: .followsFocus,
                currentTarget: zone2,
                focusedDestination: zone1,
                isMostRecentlyActive: false
            )
            assert(result, "should defer when follows-focus activation would steal a different target")
        }

        do {
            let result = FocusFollowActivationSettlementPolicy.shouldDeferImmediateRetarget(
                targetingMode: .independentOfFocus,
                currentTarget: zone2,
                focusedDestination: zone1,
                isMostRecentlyActive: false
            )
            assert(!result, "should not defer outside follows-focus mode")
        }

        do {
            let result = FocusFollowActivationSettlementPolicy.shouldDeferImmediateRetarget(
                targetingMode: .followsFocus,
                currentTarget: zone2,
                focusedDestination: zone2,
                isMostRecentlyActive: false
            )
            assert(!result, "should not defer when target already matches focused destination")
        }

        do {
            let result = FocusFollowActivationSettlementPolicy.shouldDeferImmediateRetarget(
                targetingMode: .followsFocus,
                currentTarget: floating,
                focusedDestination: floating,
                isMostRecentlyActive: false
            )
            assert(!result, "should not defer when focused floating destination already matches target")
        }

        do {
            let result = FocusFollowActivationSettlementPolicy.shouldDeferImmediateRetarget(
                targetingMode: .followsFocus,
                currentTarget: zone1,
                focusedDestination: zone2,
                isMostRecentlyActive: true
            )
            assert(!result, "should not defer when no immediate follows-focus retarget would occur")
        }

        do {
            let result = FocusFollowActivationSettlementPolicy.shouldApplySettledRetarget(
                currentTarget: zone1,
                initialTarget: zone1
            )
            assert(result, "should apply settled retarget when target stayed unchanged during settlement")
        }

        do {
            let result = FocusFollowActivationSettlementPolicy.shouldApplySettledRetarget(
                currentTarget: zone2,
                initialTarget: zone1
            )
            assert(!result, "should skip settled retarget when target changed during settlement")
        }

        do {
            let result = FocusFollowActivationSettlementPolicy.shouldApplySettledRetarget(
                currentTarget: nil,
                initialTarget: zone1
            )
            assert(!result, "should skip settled retarget when target disappeared during settlement")
        }

        return allPassed
    }
}
