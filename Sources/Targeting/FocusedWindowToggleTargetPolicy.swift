import CoreGraphics

/// Decision logic for the "Toggle Target Zone w/ Focused Window" shortcut.
///
/// A filled tiling target always advances (re-targets as if just filled), regardless of focus.
/// Otherwise, target the focused window's zone when it differs from the current target; failing that,
/// advance off the target if it holds a window (a filled floating zone), else do nothing.
enum FocusedWindowToggleTargetPolicy {
    enum Action: Equatable {
        /// Nothing to do (no focused window to target and the current target is empty).
        case none
        /// Target the focused window's zone (it is not currently targeted).
        case target(TargetedZoneManager.TargetedDestination)
        /// Advance the target off the currently targeted zone per standard fill-priority rules.
        case advance(from: TargetedZoneManager.TargetedDestination)
    }

    static func resolve(
        focusedWindowDestination: TargetedZoneManager.TargetedDestination?,
        currentTarget: TargetedZoneManager.TargetedDestination?,
        currentTargetIsOccupied: Bool
    ) -> Action {
        // A filled tiling zone as the current target always advances off itself, regardless of which
        // window (if any) is focused: re-target exactly as if that zone had just been filled.
        if let currentTarget, currentTargetIsOccupied, case .tiled = currentTarget {
            return .advance(from: currentTarget)
        }
        // Otherwise a managed window focused in a zone other than the current target moves the target there.
        if let focusedWindowDestination, focusedWindowDestination != currentTarget {
            return .target(focusedWindowDestination)
        }
        // Otherwise (focused window already in the target, or nothing focused in a zone) advance off
        // the current target, but only when it actually holds a window — at this point a filled floating zone.
        if let currentTarget, currentTargetIsOccupied {
            return .advance(from: currentTarget)
        }
        return .none
    }
}
