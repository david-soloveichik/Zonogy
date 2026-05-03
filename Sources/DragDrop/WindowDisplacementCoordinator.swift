import AppKit

/// Central coordinator for deciding how to handle windows displaced from tiled zones.
protocol DisplacedWindowCoordinatorHost: AnyObject {
    var windowPlacementManager: WindowPlacementManager { get }
    var windowController: WindowController { get }
    var targetedFloatingScreenId: CGDirectDisplayID? { get }
    func minimizeWindowProgrammatically(_ managed: ManagedWindow, reason: String)

    func hasAvailableTiledZone() -> Bool
    func activeScreenId() -> CGDirectDisplayID
    func assignWindowToFloatingZone(
        _ managed: ManagedWindow,
        on screenId: CGDirectDisplayID,
        centerWindow: Bool,
        reason: String,
        displacement: DisplacementStrategy
    )
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

        if host.hasAvailableTiledZone() {
            host.windowPlacementManager.placeNewWindow(displacedWindow, preferredScreenId: preferredScreenId)
            return
        }

        let screenId = host.targetedFloatingScreenId
            ?? preferredScreenId
            ?? host.activeScreenId()

        host.assignWindowToFloatingZone(
            displacedWindow,
            on: screenId,
            centerWindow: true,
            reason: fallbackFloatingReason,
            displacement: .synchronous
        )
    }
}
