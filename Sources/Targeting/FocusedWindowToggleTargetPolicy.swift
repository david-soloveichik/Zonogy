import CoreGraphics

/// Pure decision logic for the "Toggle Target Zone w/ Focused Window" shortcut.
///
/// Given the zone holding the focused window, the current target, and whether that target is
/// occupied, decide whether to target the focused window's zone, advance off the current target, or
/// do nothing. Advancing itself follows the standard fill-priority and is performed by
/// `TargetedZoneManager`.
enum FocusedWindowToggleTargetPolicy {
    enum Action: Equatable {
        /// Nothing to do (no focused window to target and the current target is empty).
        case none
        /// Target the focused window's zone (it is not currently targeted).
        case target(TargetedZoneManager.TargetedDestination)
        /// Advance the target off the currently targeted zone per standard rules. Triggered when the
        /// focused window already sits in the target, or when no window is focused in a zone but the
        /// target is occupied.
        case advance(from: TargetedZoneManager.TargetedDestination)
    }

    static func resolve(
        focusedWindowDestination: TargetedZoneManager.TargetedDestination?,
        currentTarget: TargetedZoneManager.TargetedDestination?,
        currentTargetIsOccupied: Bool
    ) -> Action {
        // A managed window focused in a zone other than the current target moves the target there.
        if let focusedWindowDestination, focusedWindowDestination != currentTarget {
            return .target(focusedWindowDestination)
        }
        // Otherwise (focused window already in the target, or nothing focused in a zone) advance off
        // the current target, but only when it actually holds a window.
        if let currentTarget, currentTargetIsOccupied {
            return .advance(from: currentTarget)
        }
        return .none
    }
}
