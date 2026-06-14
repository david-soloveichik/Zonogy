import CoreGraphics

/// Pure decision logic for the "Toggle Target Zone w/ Focused Window" shortcut.
///
/// Given the zone occupied by the focused window and the current target, decide whether to target
/// the focused window's zone, advance off it (when it is already targeted), or do nothing. Advancing
/// itself follows the standard fill-priority and is performed by `TargetedZoneManager`.
enum FocusedWindowToggleTargetPolicy {
    enum Action: Equatable {
        /// No focused managed window assigned to a zone: do nothing.
        case none
        /// Target the focused window's zone (it is not currently targeted).
        case target(TargetedZoneManager.TargetedDestination)
        /// The focused window's zone is already targeted: advance off it per standard rules.
        case advance(from: TargetedZoneManager.TargetedDestination)
    }

    static func resolve(
        focusedWindowDestination: TargetedZoneManager.TargetedDestination?,
        currentTarget: TargetedZoneManager.TargetedDestination?
    ) -> Action {
        guard let focusedWindowDestination else {
            return .none
        }
        if currentTarget == focusedWindowDestination {
            return .advance(from: focusedWindowDestination)
        }
        return .target(focusedWindowDestination)
    }
}
