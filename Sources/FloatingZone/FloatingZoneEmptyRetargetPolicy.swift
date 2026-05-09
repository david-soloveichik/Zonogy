/// Decides whether emptying a floating zone (via window minimize/close) should retarget
/// to that floating zone. Floating zones are "weaker" than tiling zones — they only steal
/// targeting from another floating zone, never from a tiling zone.
import Foundation
import CoreGraphics

enum FloatingZoneEmptyRetargetPolicy {
    /// Returns the screen ID to retarget the floating zone for, or `nil` to keep the current target.
    ///
    /// - Parameters:
    ///   - emptiedScreenId: The screen whose floating zone just became empty.
    ///   - currentTarget: The current targeted destination (may be `nil` if none).
    /// - Returns: `emptiedScreenId` when the current target is a floating zone on a different
    ///   screen (rule applies). `nil` when the current target is a tiling zone, the same
    ///   floating zone (already targeted), or there is no current target.
    static func retargetScreenId(
        emptiedScreenId: CGDirectDisplayID,
        currentTarget: TargetedZoneManager.TargetedDestination?
    ) -> CGDirectDisplayID? {
        guard case .floating(let currentScreenId) = currentTarget else {
            return nil
        }
        guard currentScreenId != emptiedScreenId else {
            return nil
        }
        return emptiedScreenId
    }
}
