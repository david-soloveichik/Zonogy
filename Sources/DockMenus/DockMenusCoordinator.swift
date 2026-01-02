import Foundation

/// Owns DockMenus subcomponents (Dock geometry monitoring, debug visuals) and isolates feature wiring.
final class DockMenusCoordinator {
    private let frameMonitor = DockFrameMonitor()
    private let debugOverlay: DockDebugBorderOverlayController?

    init(primaryScreenBounds: CGRect, enableDebugOverlay: Bool) {
        self.debugOverlay = enableDebugOverlay ? DockDebugBorderOverlayController(primaryScreenBounds: primaryScreenBounds) : nil

        frameMonitor.onStateChange = { [weak self] state in
            self?.debugOverlay?.setListFrame(accessibilityFrame: state.listFrame)
        }
    }

    func start() {
        Logger.debug("DockMenusCoordinator: starting (debugOverlay=\(debugOverlay != nil))")
        frameMonitor.start()
    }

    func stop() {
        Logger.debug("DockMenusCoordinator: stopping")
        frameMonitor.stop()
        debugOverlay?.setListFrame(accessibilityFrame: nil)
    }
}
