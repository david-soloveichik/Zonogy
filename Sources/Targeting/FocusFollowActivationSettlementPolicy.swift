import Foundation

/// Pure policy for deferring follows-focus retargeting while an app activation is still settling.
enum FocusFollowActivationSettlementPolicy {
    static func shouldDeferImmediateRetarget(
        targetingMode: TargetingMode,
        currentTarget: TargetedZoneManager.TargetedDestination?,
        focusedDestination: TargetedZoneManager.TargetedDestination?,
        isMostRecentlyActive: Bool
    ) -> Bool {
        guard targetingMode == .followsFocus,
              !isMostRecentlyActive,
              let currentTarget,
              let focusedDestination else {
            return false
        }

        return currentTarget != focusedDestination
    }

    static func shouldApplySettledRetarget(
        currentTarget: TargetedZoneManager.TargetedDestination?,
        initialTarget: TargetedZoneManager.TargetedDestination?
    ) -> Bool {
        currentTarget == initialTarget
    }
}
