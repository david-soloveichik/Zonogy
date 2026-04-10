import CoreGraphics

/// Pure selection logic for feature-specific active-window targeting.
/// Invariant: if Launcher is visible, it is already anchored to `currentTarget`.
enum ActiveWindowTriggeredTargetPolicy {
    static func resolveTarget(
        currentTarget: TargetedZoneManager.TargetedDestination?,
        launcherOccupiesCurrentTarget: Bool,
        activeWindow: ActiveWindowTargetResolver.ActiveWindow?
    ) -> TargetedZoneManager.TargetedDestination? {
        if launcherOccupiesCurrentTarget {
            return currentTarget
        }

        return ActiveWindowTargetResolver.resolveTarget(
            currentTarget: currentTarget,
            activeWindow: activeWindow
        )
    }
}
