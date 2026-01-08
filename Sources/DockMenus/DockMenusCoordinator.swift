import Foundation
import AppKit

/// Notified when actions occur in DockMenus that require integration with the main app.
protocol DockMenusCoordinatorDelegate: AnyObject {
    /// Called when a running app's Dock icon is clicked (intercepted).
    /// The delegate should perform the default Launcher action for this app.
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didClickDockAppWithURL appURL: URL)

    /// Returns the window that should be used when the user drags an app's Dock icon.
    /// Must follow the same "preferred window" rules as Dock click interception.
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, preferredDragWindowForDockAppWithURL appURL: URL) -> LauncherWindowItem?

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
    func dockMenusCoordinatorDidUpdateDrag(_ coordinator: DockMenusCoordinator, cursorPointAX: CGPoint?)

    /// Called when a drag session ends (mouse up).
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForWindow window: LauncherWindowItem, cursorPointAX: CGPoint?)

    // MARK: - Non-Running App Drag-and-Drop

    /// Called when a drag session begins from a non-running app's Dock icon.
    func dockMenusCoordinatorDidBeginNonRunningAppDrag(_ coordinator: DockMenusCoordinator)

    /// Called when a drag session ends for a non-running app.
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForNonRunningApp appURL: URL, cursorPointAX: CGPoint?)
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
    private var draggedNonRunningAppURL: URL?
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

        // Activate Zonogy before performing our action. See SPECIFICATION-IMPLEMENTATION.md
        // "Dock click interception activation workaround" for details.
        NSApp.activate(ignoringOtherApps: true)

        // Start ripple feedback immediately, then dispatch delegate call to let animation begin rendering
        clickFeedback.showRipple(at: itemFrame)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.dockMenusCoordinator(self, didClickDockAppWithURL: appURL)
        }
    }

    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didBeginDragOnApp appURL: URL, itemFrame: CGRect, cursorPoint: CGPoint) -> Bool {
        Logger.debug("DockMenusCoordinator: drag intercepted on running app \(appURL.lastPathComponent)")

        // Hide the DockMenu panel and reset hover state
        hideDockMenu()

        if draggedWindow != nil || draggedNonRunningAppURL != nil {
            Logger.debug("DockMenusCoordinator: drag already active; ignoring new begin")
            return true
        }

        // If app has a preferred window, drag that window
        if let window = delegate?.dockMenusCoordinator(self, preferredDragWindowForDockAppWithURL: appURL) {
            beginDrag(for: window, driveViaMouseMonitors: false, initialCursorPointAX: cursorPoint)
            delegate?.dockMenusCoordinatorDidUpdateDrag(self, cursorPointAX: cursorPoint)
            return true
        }

        // Running app with no windows - treat like non-running app (target zone and activate)
        Logger.debug("DockMenusCoordinator: running app has no windows; treating as non-running app drag")
        draggedNonRunningAppURL = appURL

        let appName = appURL.deletingPathExtension().lastPathComponent
        dragFeedback.show(title: appName, at: cocoaPoint(fromAccessibilityPoint: cursorPoint))

        delegate?.dockMenusCoordinatorDidBeginNonRunningAppDrag(self)
        delegate?.dockMenusCoordinatorDidUpdateDrag(self, cursorPointAX: cursorPoint)
        return true
    }

    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didBeginDragOnNonRunningApp appURL: URL, itemFrame: CGRect, cursorPoint: CGPoint) -> Bool {
        Logger.debug("DockMenusCoordinator: drag intercepted on non-running app \(appURL.lastPathComponent)")

        // Hide the DockMenu panel and reset hover state
        hideDockMenu()

        if draggedWindow != nil || draggedNonRunningAppURL != nil {
            Logger.debug("DockMenusCoordinator: drag already active; ignoring new begin")
            return true
        }

        // Store state for the non-running app drag
        draggedNonRunningAppURL = appURL

        // Show drag feedback with app name
        let appName = appURL.deletingPathExtension().lastPathComponent
        dragFeedback.show(title: appName, at: cocoaPoint(fromAccessibilityPoint: cursorPoint))

        // Notify delegate to show zone overlays (without a window)
        delegate?.dockMenusCoordinatorDidBeginNonRunningAppDrag(self)
        delegate?.dockMenusCoordinatorDidUpdateDrag(self, cursorPointAX: cursorPoint)
        return true
    }

    func dockClickInterceptorDidUpdateDrag(_ interceptor: DockClickInterceptor, cursorPoint: CGPoint) {
        // Handle non-running app drag
        if draggedNonRunningAppURL != nil {
            dragFeedback.updatePosition(at: cocoaPoint(fromAccessibilityPoint: cursorPoint))
            delegate?.dockMenusCoordinatorDidUpdateDrag(self, cursorPointAX: cursorPoint)
            return
        }

        // Handle running app window drag
        guard draggedWindow != nil else { return }
        dragFeedback.updatePosition(at: cocoaPoint(fromAccessibilityPoint: cursorPoint))
        delegate?.dockMenusCoordinatorDidUpdateDrag(self, cursorPointAX: cursorPoint)
    }

    func dockClickInterceptorDidEndDrag(_ interceptor: DockClickInterceptor, cursorPoint: CGPoint) {
        // Handle non-running app drag end
        if let appURL = draggedNonRunningAppURL {
            dragFeedback.hide()
            delegate?.dockMenusCoordinator(self, didEndDragForNonRunningApp: appURL, cursorPointAX: cursorPoint)
            draggedNonRunningAppURL = nil
            return
        }

        // Handle running app window drag end
        guard let window = draggedWindow else { return }
        endDrag(for: window, cursorPointAX: cursorPoint)
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
        beginDrag(for: window, driveViaMouseMonitors: true)
    }
}

// MARK: - Drag Handling

extension DockMenusCoordinator {
    private func beginDrag(for window: LauncherWindowItem, driveViaMouseMonitors: Bool, initialCursorPointAX: CGPoint? = nil) {
        // Dismiss DockMenu immediately
        hideDockMenu()

        // Store the dragged window
        draggedWindow = window

        // Show drag feedback following cursor
        if let initialCursorPointAX {
            dragFeedback.show(title: window.title, at: cocoaPoint(fromAccessibilityPoint: initialCursorPointAX))
        } else {
            dragFeedback.show(title: window.title)
        }

        // Notify delegate to start drag session (show overlays)
        delegate?.dockMenusCoordinator(self, didBeginDragForWindow: window)

        guard driveViaMouseMonitors else {
            Logger.debug("DockMenusCoordinator: drag session started (externally driven)")
            return
        }

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
            delegate?.dockMenusCoordinatorDidUpdateDrag(self, cursorPointAX: currentCursorAccessibilityPoint())

        case .leftMouseUp:
            endDrag(for: window, cursorPointAX: currentCursorAccessibilityPoint())

        default:
            break
        }
    }

    private func endDrag(for window: LauncherWindowItem, cursorPointAX: CGPoint?) {
        Logger.debug("DockMenusCoordinator: drag session ended for window \(window.title)")

        // Hide drag feedback
        dragFeedback.hide()

        // Notify delegate to end drag session and perform placement
        delegate?.dockMenusCoordinator(self, didEndDragForWindow: window, cursorPointAX: cursorPointAX)

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

    private func currentCursorAccessibilityPoint() -> CGPoint? {
        let cocoaPoint = NSEvent.mouseLocation
        let cocoaFrame = CGRect(origin: cocoaPoint, size: .zero)
        let accessibilityFrame = CoordinateConversion.cocoaToAccessibility(
            cocoaFrame: cocoaFrame,
            primaryScreenBounds: primaryScreenBounds
        )
        return accessibilityFrame.origin
    }

    private func cocoaPoint(fromAccessibilityPoint point: CGPoint) -> CGPoint {
        let accessibilityFrame = CGRect(origin: point, size: .zero)
        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: accessibilityFrame,
            primaryScreenBounds: primaryScreenBounds
        )
        return cocoaFrame.origin
    }
}
