/// Shared temporary-retarget session bookkeeping for features that may later restore the prior target.
struct TemporaryRetargetSession {
    let originalTarget: TargetedZoneManager.TargetedDestination?
    let temporaryTarget: TargetedZoneManager.TargetedDestination

    func shouldRestoreOriginalTarget(
        currentTarget: TargetedZoneManager.TargetedDestination?
    ) -> Bool {
        currentTarget == temporaryTarget
    }
}
