import CoreGraphics

/// Pure policy for deciding whether the Launcher shortcut should retarget to the active window.
enum LauncherShortcutTargetPolicy {
    static func resolveInitialTarget(
        currentTarget: TargetedZoneManager.TargetedDestination?,
        shortcutTargetsZoneWithActiveWindow: Bool,
        activeWindow: ActiveWindowTargetResolver.ActiveWindow?
    ) -> TargetedZoneManager.TargetedDestination? {
        guard shortcutTargetsZoneWithActiveWindow else {
            return currentTarget
        }

        return ActiveWindowTargetResolver.resolveTarget(
            currentTarget: currentTarget,
            activeWindow: activeWindow
        )
    }
}
