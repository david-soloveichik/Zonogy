import Foundation

/// Owns DockMenus subcomponents (Dock geometry monitoring, debug visuals, click interception) and isolates feature wiring.
final class DockMenusCoordinator {
    private let frameMonitor = DockFrameMonitor()
    private let debugOverlay: DockDebugBorderOverlayController?
    private let clickInterceptor = DockClickInterceptor()

    init(primaryScreenBounds: CGRect, enableDebugOverlay: Bool) {
        self.debugOverlay = enableDebugOverlay ? DockDebugBorderOverlayController(primaryScreenBounds: primaryScreenBounds) : nil

        frameMonitor.onStateChange = { [weak self] state in
            self?.debugOverlay?.setListFrame(accessibilityFrame: state.listFrame)
            self?.clickInterceptor.updateFrame(state.listFrame)
        }
    }

    func start() {
        Logger.debug("DockMenusCoordinator: starting (debugOverlay=\(debugOverlay != nil))")
        frameMonitor.start()
        clickInterceptor.delegate = self
        clickInterceptor.start()
    }

    func stop() {
        Logger.debug("DockMenusCoordinator: stopping")
        clickInterceptor.stop()
        frameMonitor.stop()
        debugOverlay?.setListFrame(accessibilityFrame: nil)
    }
}

extension DockMenusCoordinator: DockClickInterceptorDelegate {
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didInterceptClickAt location: CGPoint) {
        Logger.debug("DockMenusCoordinator: click intercepted at \(location)")
    }
}
