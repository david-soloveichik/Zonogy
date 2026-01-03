import Foundation

/// Notified when actions occur in DockMenus that require integration with the main app.
protocol DockMenusCoordinatorDelegate: AnyObject {
    /// Called when a running app's Dock icon is clicked (intercepted).
    /// The delegate should perform the default Launcher action for this app.
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didClickDockAppWithURL appURL: URL)

    /// Called to get the list of managed windows for an app.
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, windowsForBundleId bundleId: String) -> [LauncherWindowItem]

    /// Called when the user selects a window from the DockMenu.
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didSelectWindow window: LauncherWindowItem)

    /// Called when the user selects the app header from the DockMenu.
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didSelectAppHeader bundleId: String)
}

/// Owns DockMenus subcomponents (Dock geometry monitoring, debug visuals, click interception, hover menu) and isolates feature wiring.
final class DockMenusCoordinator {
    weak var delegate: DockMenusCoordinatorDelegate?

    private let primaryScreenBounds: CGRect
    private let frameMonitor = DockFrameMonitor()
    private let debugOverlay: DockDebugBorderOverlayController?
    private let clickInterceptor = DockClickInterceptor()
    private let clickFeedback: DockClickFeedbackOverlay
    private let hoverTracker = DockHoverTracker()
    private let panelController = DockMenuPanelController()

    init(primaryScreenBounds: CGRect, enableDebugOverlay: Bool) {
        self.primaryScreenBounds = primaryScreenBounds
        self.debugOverlay = enableDebugOverlay ? DockDebugBorderOverlayController(primaryScreenBounds: primaryScreenBounds) : nil
        self.clickFeedback = DockClickFeedbackOverlay(primaryScreenBounds: primaryScreenBounds)

        frameMonitor.onStateChange = { [weak self] state in
            // Debug overlay only shows when Dock is visible
            self?.debugOverlay?.setListFrame(accessibilityFrame: state.isVisible ? state.listFrame : nil)
            self?.clickInterceptor.updateFrame(state.listFrame)
            self?.clickInterceptor.updateVisibility(state.isVisible)
        }

        clickInterceptor.onDockNotFound = { [weak self] in
            self?.frameMonitor.markDockHidden()
        }

        frameMonitor.onAppHover = { [weak self] event in
            self?.hoverTracker.handleHoverEvent(event)
        }

        hoverTracker.onStableHover = { [weak self] event in
            self?.showDockMenu(for: event)
        }

        hoverTracker.onHoverEnd = { [weak self] in
            self?.hideDockMenu()
        }

        panelController.delegate = self
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
        hoverTracker.reset()
        panelController.hide()
    }

    // MARK: - Private

    private func showDockMenu(for event: DockMenuHoverEvent) {
        // Get windows from delegate
        let windows = delegate?.dockMenusCoordinator(self, windowsForBundleId: event.bundleIdentifier) ?? []

        // Use stable Dock frame for positioning (handles autohide animation)
        let stableDockFrame = frameMonitor.stableDockFrame ?? event.listFrame

        Logger.debug("DockMenusCoordinator: showing DockMenu for \(event.appURL.lastPathComponent) with \(windows.count) windows")
        panelController.show(for: event, windows: windows, stableDockFrame: stableDockFrame)
    }

    private func hideDockMenu() {
        panelController.hide()
    }
}

extension DockMenusCoordinator: DockClickInterceptorDelegate {
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didInterceptClickOnApp appURL: URL, itemFrame: CGRect) {
        Logger.debug("DockMenusCoordinator: click intercepted on app \(appURL.lastPathComponent)")

        // Hide the DockMenu panel and reset hover state
        hoverTracker.actionPerformed()

        // Start ripple feedback immediately, then dispatch delegate call to let animation begin rendering
        clickFeedback.showRipple(at: itemFrame)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.dockMenusCoordinator(self, didClickDockAppWithURL: appURL)
        }
    }
}

// MARK: - DockMenuPanelControllerDelegate

extension DockMenusCoordinator: DockMenuPanelControllerDelegate {
    func dockMenuPanelController(_ controller: DockMenuPanelController, didSelectWindow window: LauncherWindowItem) {
        Logger.debug("DockMenusCoordinator: window selected in panel")
        hoverTracker.actionPerformed()
        delegate?.dockMenusCoordinator(self, didSelectWindow: window)
    }

    func dockMenuPanelControllerDidSelectAppHeader(_ controller: DockMenuPanelController, bundleIdentifier: String) {
        Logger.debug("DockMenusCoordinator: app header selected in panel")
        hoverTracker.actionPerformed()
        delegate?.dockMenusCoordinator(self, didSelectAppHeader: bundleIdentifier)
    }

    func dockMenuPanelControllerCursorExitedPanel(_ controller: DockMenuPanelController) {
        hoverTracker.cursorExitedPanel()
    }

    func dockMenuPanelControllerCursorEnteredPanel(_ controller: DockMenuPanelController) {
        hoverTracker.cursorEnteredPanel()
    }
}
