import CoreGraphics

/// Pure policy for deciding whether the Launcher shortcut should retarget to the active window.
enum LauncherShortcutTargetPolicy {
    struct RepeatedShortcutResolution {
        let originalTarget: TargetedZoneManager.TargetedDestination?
        let nextTarget: TargetedZoneManager.TargetedDestination
    }

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

    static func resolveRepeatedTarget(
        currentTarget: TargetedZoneManager.TargetedDestination?,
        existingSession: TemporaryRetargetSession?,
        activeWindow: ActiveWindowTargetResolver.ActiveWindow?
    ) -> RepeatedShortcutResolution? {
        let originalTarget: TargetedZoneManager.TargetedDestination?
        if let existingSession {
            originalTarget = existingSession.originalTarget
        } else {
            originalTarget = currentTarget
        }

        guard let activeWindowTarget = ActiveWindowTargetResolver.resolveTarget(
            currentTarget: nil,
            activeWindow: activeWindow
        ) else {
            return nil
        }

        let candidateTarget = currentTarget == originalTarget
            ? activeWindowTarget
            : originalTarget

        guard let nextTarget = candidateTarget,
              nextTarget != currentTarget else {
            return nil
        }

        return RepeatedShortcutResolution(
            originalTarget: originalTarget,
            nextTarget: nextTarget
        )
    }
}
