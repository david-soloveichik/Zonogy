import Foundation

/// Notified when actions occur in DockMenus that require integration with the main app.
protocol DockMenusCoordinatorDelegate: AnyObject {
    /// Called when a running app's Dock icon is clicked (intercepted).
    /// The delegate should perform the default Launcher action for this app.
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didClickDockAppWithURL appURL: URL)
}

/// Owns DockMenus subcomponents (Dock geometry monitoring, debug visuals, click interception) and isolates feature wiring.
final class DockMenusCoordinator {
    weak var delegate: DockMenusCoordinatorDelegate?

    private let primaryScreenBounds: CGRect
    private let frameMonitor = DockFrameMonitor()
    private let debugOverlay: DockDebugBorderOverlayController?
    private let clickInterceptor = DockClickInterceptor()
    private let clickFeedback: DockClickFeedbackOverlay

    init(primaryScreenBounds: CGRect, enableDebugOverlay: Bool) {
        self.primaryScreenBounds = primaryScreenBounds
        self.debugOverlay = enableDebugOverlay ? DockDebugBorderOverlayController(primaryScreenBounds: primaryScreenBounds) : nil
        self.clickFeedback = DockClickFeedbackOverlay(primaryScreenBounds: primaryScreenBounds)

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
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didInterceptClickOnApp appURL: URL, itemFrame: CGRect) {
        Logger.debug("DockMenusCoordinator: click intercepted on app \(appURL.lastPathComponent)")
        clickFeedback.showRipple(at: itemFrame)
        delegate?.dockMenusCoordinator(self, didClickDockAppWithURL: appURL)
    }
}
