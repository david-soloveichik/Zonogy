import Foundation

/// Owns DockMenus subcomponents (Dock geometry monitoring, debug visuals) and isolates feature wiring.
final class DockMenusCoordinator {
    private let frameMonitor: DockFrameMonitor
    private let debugOverlay: DockDebugBorderOverlayController?
    private let refreshCoalesceInterval: TimeInterval

    init(primaryScreenBounds: CGRect, enableDebugOverlay: Bool, refreshCoalesceInterval: TimeInterval = 0.05) {
        self.refreshCoalesceInterval = refreshCoalesceInterval
        self.frameMonitor = DockFrameMonitor(refreshCoalesceInterval: refreshCoalesceInterval)
        self.debugOverlay = enableDebugOverlay ? DockDebugBorderOverlayController(primaryScreenBounds: primaryScreenBounds) : nil

        frameMonitor.onStateChange = { [weak self] state in
            self?.debugOverlay?.setDockFrame(accessibilityFrame: state.dockFrame, isVisible: state.isDockVisible)
            self?.debugOverlay?.setListFrame(accessibilityFrame: state.listFrame)
        }
    }

    func start() {
        Logger.debug("DockMenusCoordinator: starting (debugOverlay=\(debugOverlay != nil), refreshCoalesce=\(String(format: "%.2f", refreshCoalesceInterval)))")
        frameMonitor.start()
    }

    func stop() {
        Logger.debug("DockMenusCoordinator: stopping")
        frameMonitor.stop()
        debugOverlay?.setDockFrame(accessibilityFrame: nil, isVisible: false)
    }

    func refreshNow() {
        frameMonitor.refreshNow()
    }
}
