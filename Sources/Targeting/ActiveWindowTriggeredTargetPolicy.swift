import CoreGraphics

/// Pure selection logic for feature-specific active-window targeting.
/// Invariant: if Launcher is visible, it is already anchored to `currentTarget`.
enum ActiveWindowTriggeredTargetPolicy {
    struct ActiveWindow {
        let screenId: CGDirectDisplayID
        let zoneIndex: Int?
        let isInFloatingZone: Bool
    }

    static func resolveTarget(
        currentTarget: TargetedZoneManager.TargetedDestination?,
        launcherOccupiesCurrentTarget: Bool,
        activeWindow: ActiveWindow?
    ) -> TargetedZoneManager.TargetedDestination? {
        if launcherOccupiesCurrentTarget {
            return currentTarget
        }

        guard let activeWindow else {
            return currentTarget
        }

        if let zoneIndex = activeWindow.zoneIndex {
            return .tiled(ZoneKey(screenId: activeWindow.screenId, index: zoneIndex))
        }

        if activeWindow.isInFloatingZone {
            return .floating(screenId: activeWindow.screenId)
        }

        return currentTarget
    }
}
