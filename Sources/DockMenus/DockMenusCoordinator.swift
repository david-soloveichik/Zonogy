import Foundation
import AppKit

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

    // MARK: - Drag-and-Drop

    /// Called when a drag session begins from a DockMenu window entry.
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didBeginDragForWindow window: LauncherWindowItem)

    /// Called repeatedly during a drag session as the cursor moves.
    func dockMenusCoordinatorDidUpdateDrag(_ coordinator: DockMenusCoordinator)

    /// Called when a drag session ends (mouse up).
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForWindow window: LauncherWindowItem)
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
    private let dismissalPoller = DockMenuDismissalPoller()
    private let dragFeedback = DockMenuDragFeedback()

    private var lastHoverEvent: DockMenuHoverEvent?
    private var lastDockFrameAX: CGRect?
    private static let dockSafePadding: CGFloat = 12

    // Drag state
    private var draggedWindow: LauncherWindowItem?
    private var dragGlobalMonitor: Any?
    private var dragLocalMonitor: Any?

    init(primaryScreenBounds: CGRect, enableDebugOverlay: Bool) {
        self.primaryScreenBounds = primaryScreenBounds
        self.debugOverlay = enableDebugOverlay ? DockDebugBorderOverlayController(primaryScreenBounds: primaryScreenBounds) : nil
        self.clickFeedback = DockClickFeedbackOverlay(primaryScreenBounds: primaryScreenBounds)

        frameMonitor.onStateChange = { [weak self] state in
            // Debug overlay only shows when Dock is visible
            self?.debugOverlay?.setListFrame(accessibilityFrame: state.isVisible ? state.listFrame : nil)
            self?.clickInterceptor.updateFrame(state.listFrame)
            self?.clickInterceptor.updateVisibility(state.isVisible)
            self?.lastDockFrameAX = state.listFrame
        }

        clickInterceptor.onDockNotFound = { [weak self] in
            self?.frameMonitor.markDockHidden()
        }

        frameMonitor.onAppHover = { [weak self] event in
            self?.lastHoverEvent = event
            self?.hoverTracker.handleHoverEvent(event)
        }

        hoverTracker.onStableHover = { [weak self] event in
            self?.showDockMenu(for: event)
        }

        dismissalPoller.isCursorInSafeRegion = { [weak self] in
            self?.isCursorInSafeRegion() ?? true
        }
        dismissalPoller.onGraceExpired = { [weak self] in
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
        dismissalPoller.stop()
        hoverTracker.reset()
        panelController.hide()
    }

    // MARK: - Private

    private func showDockMenu(for event: DockMenuHoverEvent) {
        let stableDockFrame = frameMonitor.stableDockFrame ?? event.listFrame
        lastDockFrameAX = stableDockFrame

        if !isCursorInDockFrame(stableDockFrame) {
            Logger.debug("DockMenusCoordinator: skipping DockMenu show (cursor not in Dock)")
            return
        }

        // Get windows from delegate
        let windows = delegate?.dockMenusCoordinator(self, windowsForBundleId: event.bundleIdentifier) ?? []

        Logger.debug("DockMenusCoordinator: showing DockMenu for \(event.appURL.lastPathComponent) with \(windows.count) windows")
        panelController.show(for: event, windows: windows, stableDockFrame: stableDockFrame)
        hoverTracker.menuDidShow(appURL: event.appURL)
        dismissalPoller.start()
    }

    private func hideDockMenu() {
        dismissalPoller.stop()
        panelController.hide()
        hoverTracker.reset()
    }

    private func isCursorInSafeRegion() -> Bool {
        guard panelController.isVisible else { return true }

        let mouseLocation = NSEvent.mouseLocation
        if panelController.panelFrame?.contains(mouseLocation) == true {
            return true
        }

        guard lastHoverEvent != nil, let dockFrameAX = lastDockFrameAX else {
            return false
        }

        return isCursorInDockFrame(dockFrameAX)
    }

    private func isCursorInDockFrame(_ dockFrameAX: CGRect) -> Bool {
        let dockFrameCocoa = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: dockFrameAX,
            primaryScreenBounds: primaryScreenBounds
        )
        return dockFrameCocoa.insetBy(dx: -Self.dockSafePadding, dy: -Self.dockSafePadding).contains(NSEvent.mouseLocation)
    }
}

extension DockMenusCoordinator: DockClickInterceptorDelegate {
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didInterceptClickOnApp appURL: URL, itemFrame: CGRect) {
        Logger.debug("DockMenusCoordinator: click intercepted on app \(appURL.lastPathComponent)")

        // Hide the DockMenu panel and reset hover state
        hideDockMenu()

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
        hideDockMenu()
        delegate?.dockMenusCoordinator(self, didSelectWindow: window)
    }

    func dockMenuPanelControllerDidSelectAppHeader(_ controller: DockMenuPanelController, bundleIdentifier: String) {
        Logger.debug("DockMenusCoordinator: app header selected in panel")
        hideDockMenu()
        delegate?.dockMenusCoordinator(self, didSelectAppHeader: bundleIdentifier)
    }

    func dockMenuPanelController(_ controller: DockMenuPanelController, didBeginDragForWindow window: LauncherWindowItem) {
        Logger.debug("DockMenusCoordinator: drag began for window \(window.title)")
        beginDrag(for: window)
    }
}

// MARK: - Drag Handling

extension DockMenusCoordinator {
    private func beginDrag(for window: LauncherWindowItem) {
        // Dismiss DockMenu immediately
        hideDockMenu()

        // Store the dragged window
        draggedWindow = window

        // Show drag feedback following cursor
        dragFeedback.show(title: window.title)

        // Notify delegate to start drag session (show overlays)
        delegate?.dockMenusCoordinator(self, didBeginDragForWindow: window)

        // Install both local and global mouse monitors for drag tracking
        // Global monitor catches events when other apps have focus
        dragGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleDragMouseEvent(event)
        }

        // Local monitor catches events when our app has focus (or during transition)
        dragLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleDragMouseEvent(event)
            return event  // Don't consume the event
        }

        Logger.debug("DockMenusCoordinator: drag session started, mouse monitors installed")
    }

    private func handleDragMouseEvent(_ event: NSEvent) {
        guard let window = draggedWindow else { return }

        switch event.type {
        case .leftMouseDragged:
            dragFeedback.updatePosition()
            delegate?.dockMenusCoordinatorDidUpdateDrag(self)

        case .leftMouseUp:
            endDrag(for: window)

        default:
            break
        }
    }

    private func endDrag(for window: LauncherWindowItem) {
        Logger.debug("DockMenusCoordinator: drag session ended for window \(window.title)")

        // Hide drag feedback
        dragFeedback.hide()

        // Notify delegate to end drag session and perform placement
        delegate?.dockMenusCoordinator(self, didEndDragForWindow: window)

        // Clean up monitors
        if let monitor = dragGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            dragGlobalMonitor = nil
        }
        if let monitor = dragLocalMonitor {
            NSEvent.removeMonitor(monitor)
            dragLocalMonitor = nil
        }
        draggedWindow = nil
    }
}
