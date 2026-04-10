import CoreGraphics

/// Pure mapping from the active managed window's placement to a targeted destination.
enum ActiveWindowTargetResolver {
    struct ActiveWindow {
        let screenId: CGDirectDisplayID
        let zoneIndex: Int?
        let isInFloatingZone: Bool
    }

    static func resolveTarget(
        currentTarget: TargetedZoneManager.TargetedDestination?,
        activeWindow: ActiveWindow?
    ) -> TargetedZoneManager.TargetedDestination? {
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
