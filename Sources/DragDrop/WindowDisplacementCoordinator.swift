import AppKit

/// Central coordinator for deciding how to handle windows displaced from tiled zones.
protocol DisplacedWindowCoordinatorHost: AnyObject {
    var windowPlacementManager: WindowPlacementManager { get }
    var targetedZoneManager: TargetedZoneManager { get }
    var targetedFloatingScreenId: CGDirectDisplayID? { get }
    func minimizeWindowProgrammatically(_ managed: ManagedWindow, reason: String)

    func activeScreenId() -> CGDirectDisplayID
}

final class DisplacedWindowCoordinator {
    weak var host: DisplacedWindowCoordinatorHost?

    init(host: DisplacedWindowCoordinatorHost) {
        self.host = host
    }

    func resolve(
        _ displacedWindow: ManagedWindow?,
        preferredScreenId: CGDirectDisplayID?,
        disposition: DisplacedWindowDisposition,
        fallbackFloatingReason: String = "displaced-no-empty-zones"
    ) {
        guard let host, let displacedWindow else { return }

        switch disposition {
        case .minimize:
            host.minimizeWindowProgrammatically(displacedWindow, reason: "displaced-window")
            Logger.debug("Minimized displaced window \(displacedWindow.windowId) per displacement policy")
            return
        case .reassign:
            break
        }

        // Pin the placement to a display that actually has an empty tiling zone — the drop
        // display when it has one, otherwise any display with room. Preferring a full display
        // would make the per-display placement evict its highest-index occupant even though
        // room exists elsewhere. Deliberately counts targetable displays only: a full-screen-
        // paused display's empty zones cannot receive the displaced window, so it falls
        // through to the floating fallback instead.
        let emptyZone = preferredScreenId.flatMap { host.targetedZoneManager.lowestIndexEmptyZoneOnSameScreen(screenId: $0) }
            ?? host.targetedZoneManager.lowestIndexEmptyZone(preferredScreenId: preferredScreenId)
        if let emptyZone {
            host.windowPlacementManager.placeNewWindow(displacedWindow, preferredScreenId: emptyZone.screenId)
            return
        }

        let screenId = host.targetedFloatingScreenId
            ?? preferredScreenId
            ?? host.activeScreenId()

        // Route through placeWindow so filling a targeted floating zone advances the target
        // per the standard retarget-after-fill rule (this fallback typically lands in the
        // floating zone the preceding tiled fill just targeted).
        host.windowPlacementManager.placeWindow(
            displacedWindow,
            into: .floating(screenId: screenId),
            reason: fallbackFloatingReason,
            retargetOnRemoval: false,
            logIfUnassignedOnRemoval: false
        )
    }
}
