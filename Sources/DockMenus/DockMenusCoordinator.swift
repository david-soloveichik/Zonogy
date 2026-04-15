import Foundation
import AppKit

/// Notified when actions occur in DockMenus that require integration with the main app.
protocol DockMenusCoordinatorDelegate: AnyObject {
    /// Called when a running app's Dock icon is clicked (intercepted).
    /// The delegate should perform the default Launcher action for this app.
    /// - Parameters:
    ///   - dockItemElement: The accessibility element of the clicked Dock item, which can be used
    ///     to simulate a press if needed (e.g., for apps with no windows).
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didClickDockAppWithURL appURL: URL, dockItemElement: AXUIElement)

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
    private enum DragPayload {
        case window(LauncherWindowItem)
        case nonRunningApp(URL)
    }

    weak var delegate: DockMenusCoordinatorDelegate?

    private let primaryScreenBounds: CGRect
    private let frameMonitor = DockFrameMonitor()
    private let debugOverlay: DockDebugBorderOverlayController?
    private let clickInterceptor = DockClickInterceptor()
    private let clickFeedback: DockClickFeedbackOverlay
    private let hoverTracker = DockHoverTracker()
    private let panelController = DockMenuPanelController()
    private let dismissalPoller = DockMenuDismissalPoller()

    private var lastHoverEvent: DockMenuHoverEvent?
    private var lastDockFrameAX: CGRect?
    private static let dockSafePadding: CGFloat = 12

    private lazy var rowDragController = CursorDrivenRowDragController<DragPayload>(
        logPrefix: "DockMenusCoordinator",
        currentCursorAXProvider: { [weak self] in
            self?.currentCursorAccessibilityPoint()
        },
        onDidBeginDrag: { [weak self] payload in
            guard let self else { return }
            switch payload {
            case .window(let window):
                Logger.debug("DockMenusCoordinator: drag began for window \(window.title)")
                self.delegate?.dockMenusCoordinator(self, didBeginDragForWindow: window)
            case .nonRunningApp:
                Logger.debug("DockMenusCoordinator: non-running app drag began")
                self.delegate?.dockMenusCoordinatorDidBeginNonRunningAppDrag(self)
            }
        },
        onDidUpdateDrag: { [weak self] cursorPointAX in
            guard let self else { return }
            self.delegate?.dockMenusCoordinatorDidUpdateDrag(self, cursorPointAX: cursorPointAX)
        },
        onDidEndDrag: { [weak self] payload, cursorPointAX in
            guard let self else { return }
            switch payload {
            case .window(let window):
                Logger.debug("DockMenusCoordinator: drag session ended for window \(window.title)")
                self.delegate?.dockMenusCoordinator(self, didEndDragForWindow: window, cursorPointAX: cursorPointAX)
            case .nonRunningApp(let appURL):
                Logger.debug("DockMenusCoordinator: drag session ended for non-running app \(appURL.lastPathComponent)")
                self.delegate?.dockMenusCoordinator(self, didEndDragForNonRunningApp: appURL, cursorPointAX: cursorPointAX)
            }
        }
    )

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
        rowDragController.cancelDrag()
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
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didInterceptClickOnApp appURL: URL, itemFrame: CGRect, dockItemElement: AXUIElement) {
        Logger.debug("DockMenusCoordinator: click intercepted on app \(appURL.lastPathComponent)")

        hideDockMenu()
        clickFeedback.showRipple(at: itemFrame)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.dockMenusCoordinator(self, didClickDockAppWithURL: appURL, dockItemElement: dockItemElement)
        }
    }

    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didBeginDragOnApp appURL: URL, itemFrame: CGRect, cursorPoint: CGPoint) -> Bool {
        Logger.debug("DockMenusCoordinator: drag intercepted on running app \(appURL.lastPathComponent)")
        hideDockMenu()

        if rowDragController.isDragging {
            Logger.debug("DockMenusCoordinator: drag already active; ignoring new begin")
            return true
        }

        let initialCocoaPoint = cocoaPoint(fromAccessibilityPoint: cursorPoint)

        if let window = delegate?.dockMenusCoordinator(self, preferredDragWindowForDockAppWithURL: appURL) {
            rowDragController.beginDrag(
                for: .window(window),
                title: window.title,
                initialCursorPointCocoa: initialCocoaPoint,
                driveViaMouseMonitors: false
            )
            rowDragController.updateDrag(cursorPointAX: cursorPoint, cursorPointCocoa: initialCocoaPoint)
            return true
        }

        Logger.debug("DockMenusCoordinator: running app has no windows; treating as non-running app drag")
        let appName = appURL.deletingPathExtension().lastPathComponent
        rowDragController.beginDrag(
            for: .nonRunningApp(appURL),
            title: appName,
            initialCursorPointCocoa: initialCocoaPoint,
            driveViaMouseMonitors: false
        )
        rowDragController.updateDrag(cursorPointAX: cursorPoint, cursorPointCocoa: initialCocoaPoint)
        return true
    }

    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didBeginDragOnNonRunningApp appURL: URL, itemFrame: CGRect, cursorPoint: CGPoint) -> Bool {
        Logger.debug("DockMenusCoordinator: drag intercepted on non-running app \(appURL.lastPathComponent)")
        hideDockMenu()

        if rowDragController.isDragging {
            Logger.debug("DockMenusCoordinator: drag already active; ignoring new begin")
            return true
        }

        let appName = appURL.deletingPathExtension().lastPathComponent
        let initialCocoaPoint = cocoaPoint(fromAccessibilityPoint: cursorPoint)
        rowDragController.beginDrag(
            for: .nonRunningApp(appURL),
            title: appName,
            initialCursorPointCocoa: initialCocoaPoint,
            driveViaMouseMonitors: false
        )
        rowDragController.updateDrag(cursorPointAX: cursorPoint, cursorPointCocoa: initialCocoaPoint)
        return true
    }

    func dockClickInterceptorDidUpdateDrag(_ interceptor: DockClickInterceptor, cursorPoint: CGPoint) {
        rowDragController.updateDrag(
            cursorPointAX: cursorPoint,
            cursorPointCocoa: cocoaPoint(fromAccessibilityPoint: cursorPoint)
        )
    }

    func dockClickInterceptorDidEndDrag(_ interceptor: DockClickInterceptor, cursorPoint: CGPoint) {
        rowDragController.endDrag(cursorPointAX: cursorPoint)
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
        hideDockMenu()
        rowDragController.beginDrag(
            for: .window(window),
            title: window.title,
            driveViaMouseMonitors: true
        )
    }
}

extension DockMenusCoordinator {
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
