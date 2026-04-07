import Foundation

/// Pure policy for suppressing follows-focus retargets that would override an empty-zone retarget.
///
/// When a tiled window is closed or minimized, the zone empties and Zonogy retargets to it
/// (spec rule: "whenever a tiling zone becomes empty, target that zone"). The OS then
/// automatically focuses a sibling window in the same app, which — in follows-focus mode —
/// would immediately steal the target away from the empty zone. This policy suppresses that
/// automatic retarget while allowing intentional user focus changes through.
enum EmptyZoneRetargetProtectionPolicy {
    static func shouldSuppressRetarget(
        protectedZone: ZoneKey,
        protectedPid: pid_t,
        protectedWindowId: Int,
        currentTarget: TargetedZoneManager.TargetedDestination?,
        incomingPid: pid_t,
        incomingWindowId: Int,
        deadline: Date,
        now: Date
    ) -> Bool {
        // Only suppress if the deadline hasn't passed.
        guard now < deadline else {
            return false
        }

        // Only suppress if the current target is still the protected empty zone
        // (nothing else has changed the target in the meantime).
        guard currentTarget == .tiled(protectedZone) else {
            return false
        }

        // Only suppress retargets from the same app whose window disappeared.
        // Cross-app focus changes are intentional user actions.
        guard incomingPid == protectedPid else {
            return false
        }

        // Only suppress the specific sibling window expected to receive the automatic fallback
        // focus after the removed window disappears. A different same-app window should retarget.
        guard incomingWindowId == protectedWindowId else {
            return false
        }

        return true
    }
}
