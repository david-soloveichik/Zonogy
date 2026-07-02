import AppKit
import ApplicationServices
import Foundation

/// DockMenus feature wiring and lifecycle management.
extension AppController {
    internal var isDockMenusEnabledInSettings: Bool {
        DockMenusPreferencesStore.loadEnabled()
    }

    internal var isDockMenusDebugOverlayEnabledInSettings: Bool {
        DebugPreferencesStore.loadDockMenusOverlayEnabled()
    }

    internal func startDockMenusIfConfigured() {
        let dockMenusConfig = effectiveDockMenusConfiguration()
        guard dockMenusConfig.isEnabled || dockMenusConfig.showsDockFrameOverlay else {
            Logger.debug("DockMenus: disabled")
            return
        }

        Logger.debug("DockMenus: enabled (debugOverlay=\(dockMenusConfig.showsDockFrameOverlay))")
        let coordinator = DockMenusCoordinator(
            primaryScreenBounds: screenContextStore.primaryScreenBounds,
            enableDebugOverlay: dockMenusConfig.showsDockFrameOverlay
        )
        coordinator.delegate = self
        coordinator.isClickPointCoveredByZonogyEdgeUI = { [weak self] point in
            self?.isPointCoveredByZonogyEdgePill(point) ?? false
        }
        dockMenusCoordinator = coordinator
        coordinator.start()
    }

    internal func stopDockMenus() {
        Logger.debug("DockMenus: stop requested")
        dockMenusCoordinator?.stop()
        dockMenusCoordinator = nil
    }

    internal func setDockMenusEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("DockMenus: settings updated enabled=\(enabled)")
        DockMenusPreferencesStore.saveEnabled(enabled)
        applyDockMenusConfiguration()
    }

    internal func setDockMenusDebugOverlayEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("DockMenus: settings updated debugOverlay=\(enabled)")
        DebugPreferencesStore.saveDockMenusOverlayEnabled(enabled)
        applyDockMenusConfiguration()
    }

    private func effectiveDockMenusConfiguration() -> DockMenusConfiguration {
        DockMenusConfiguration(
            enabled: DockMenusPreferencesStore.loadEnabled(),
            debugDockFrameOverlay: DebugPreferencesStore.loadDockMenusOverlayEnabled()
        )
    }

    private func applyDockMenusConfiguration() {
        stopDockMenus()
        startDockMenusIfConfigured()
    }

    /// True when the point lands on the current on-screen frame of an add-zone or floating-zone
    /// pill window. Uses the live window frames — which already reflect hover/drag/pulse
    /// expansion — rather than inflated resting frames, so Dock icons next to a resting pill
    /// keep normal DockMenus interception right up to the pill's visible edge.
    private func isPointCoveredByZonogyEdgePill(_ point: CGPoint) -> Bool {
        let cocoaFrames = addZoneIndicatorManager.presentedWindowFrames
            + floatingIndicatorManager.presentedWindowFrames
        return cocoaFrames.contains { cocoaFrame in
            CoordinateConversion.cocoaToAccessibility(
                cocoaFrame: cocoaFrame,
                primaryScreenBounds: windowController.primaryScreenBounds
            ).contains(point)
        }
    }
}

// MARK: - DockMenusCoordinatorDelegate

extension AppController: DockMenusCoordinatorDelegate {
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didClickDockAppWithURL appURL: URL, dockItemElement: AXUIElement) {
        Logger.debug("DockMenus: click on \(appURL.lastPathComponent)")
        if shouldDockMenusRetargetForAppClick(appURL) {
            retargetDockMenusToActiveWindowIfNeeded(reason: "dockmenu-click")
        }
        // DockMenus uses activateInPlace:true - windows already in a zone are activated
        // without being moved to the targeted zone (unlike the Launcher)
        performDefaultLauncherAction(for: appURL, activateInPlace: true, dockItemElement: dockItemElement)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, preferredDragWindowForDockAppWithURL appURL: URL) -> LauncherWindowItem? {
        preferredDragWindowItem(forAppURL: appURL)
    }

    internal func preferredDragWindowItem(forAppURL appURL: URL) -> LauncherWindowItem? {
        guard let bundleId = ApplicationIdentity.bundleIdentifier(forApplicationURL: appURL),
              let preferredManaged = preferredManagedWindowForRunningApp(bundleIdentifier: bundleId) else {
            return nil
        }

        if let item = windowsForApp(bundleIdentifier: bundleId).first(where: { $0.managedWindowId == preferredManaged.windowId }) {
            return item
        }

        // Fallback: construct a minimal LauncherWindowItem for drag feedback and placement.
        // The window may be parked — do NOT gate on `isPlacedInZone`; the user is initiating a
        // drag and needs a displayable title. Use the shared resolver so the empty-title fallback
        // (document filename, then app name) matches the Launcher/DockMenus/CmdTab lists.
        let element = preferredManaged.backing.element
        let pid = preferredManaged.backing.pid

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
        let title = SwitcherWindowTitle.resolve(for: element, appName: appName)

        return LauncherWindowItem(
            title: title,
            isPlacedInZone: preferredManaged.isPlacedInZone,
            axElement: element,
            lastActiveTime: windowController.lastActiveTime(for: preferredManaged.windowId),
            bundleIdentifier: bundleId,
            pid: pid,
            managedWindowId: preferredManaged.windowId
        )
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, windowsForBundleId bundleId: String) -> [LauncherWindowItem] {
        // Reuse the existing LauncherWindowProvider implementation
        return windowsForApp(bundleIdentifier: bundleId)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didSelectWindow window: LauncherWindowItem) {
        Logger.debug("DockMenus: window selected \(window.title)")
        if shouldDockMenusRetargetForWindowSelection(window) {
            retargetDockMenusToActiveWindowIfNeeded(reason: "dockmenu-window-selection")
        }
        // Reuse Launcher's window selection with activateInPlace semantics
        handleWindowSelection(window, activateInPlace: true)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didSelectAppHeader bundleId: String) {
        Logger.debug("DockMenus: app header selected for \(bundleId)")
        // Hide the Launcher if it's open
        if launcherController.isActive {
            launcherController.hide()
        }
        // Activate the app without targeting a specific window
        if let app = ApplicationIdentity.runningApplication(bundleIdentifier: bundleId) {
            app.activate()
        }
    }

    // MARK: - Drag-and-Drop

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didBeginDragForWindow window: LauncherWindowItem, appURL: URL) {
        Logger.debug("DockMenus: drag began for window \(window.title)")
        launcherController.hide()
        // Begin in window-drag mode; the drop handler checks Option state and may switch
        // to a new-window action using `appURL`.
        _ = beginCursorDrivenWindowDrag(for: window)
    }

    func dockMenusCoordinatorDidUpdateDrag(_ coordinator: DockMenusCoordinator, cursorPointAX: CGPoint?) {
        // Update the cursor-driven drag session
        dragDropCoordinator.updateCursorDrivenDragSession(cursorPointAX: cursorPointAX)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForWindow window: LauncherWindowItem, appURL: URL, cursorPointAX: CGPoint?) {
        Logger.debug("DockMenus: drag ended for window \(window.title)")
        if NSEvent.modifierFlags.contains(.option) {
            Logger.debug("DockMenus: Option held at drop — switching to new-window for \(appURL.lastPathComponent)")
            _ = performCursorDrivenNewWindowDrop(
                for: appURL,
                cursorPointAX: cursorPointAX,
                reason: "dock-option-drag"
            )
            return
        }
        _ = performCursorDrivenManagedWindowDrop(
            for: window,
            cursorPointAX: cursorPointAX,
            reason: "dockmenu-drag"
        )
    }

    // MARK: - Non-Running App Drag-and-Drop

    func dockMenusCoordinatorDidBeginNonRunningAppDrag(_ coordinator: DockMenusCoordinator) {
        Logger.debug("DockMenus: non-running app drag began")
        launcherController.hide()
        beginCursorDrivenLaunchTargetDrag()
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForNonRunningApp appURL: URL, cursorPointAX: CGPoint?) {
        Logger.debug("DockMenus: dock-app drag ended for \(appURL.lastPathComponent)")
        if NSEvent.modifierFlags.contains(.option) {
            Logger.debug("DockMenus: Option held at drop — switching to new-window for \(appURL.lastPathComponent)")
            _ = performCursorDrivenNewWindowDrop(
                for: appURL,
                cursorPointAX: cursorPointAX,
                reason: "dock-option-drag"
            )
            return
        }
        _ = performCursorDrivenAppDrop(
            for: appURL,
            cursorPointAX: cursorPointAX,
            reason: "dock-nonrunning-drag"
        )
    }

    // MARK: - Drag Cancellation

    func dockMenusCoordinatorDidCancelDrag(_ coordinator: DockMenusCoordinator) {
        Logger.debug("DockMenus: drag cancelled by user (Escape)")
        dragDropCoordinator.tearDownDragSession()
    }

    private func shouldDockMenusRetargetForAppClick(_ appURL: URL) -> Bool {
        guard dockMenusTargetsZoneWithActiveWindowEnabled else {
            return false
        }

        guard let bundleId = ApplicationIdentity.bundleIdentifier(forApplicationURL: appURL),
              let preferredWindow = preferredManagedWindowForRunningApp(bundleIdentifier: bundleId) else {
            return true
        }

        return !preferredWindow.isPlacedInZone
    }

    private func shouldDockMenusRetargetForWindowSelection(_ window: LauncherWindowItem) -> Bool {
        guard dockMenusTargetsZoneWithActiveWindowEnabled else {
            return false
        }

        if let managedWindowId = window.managedWindowId,
           let managed = windowController.window(withId: managedWindowId) {
            return !managed.isPlacedInZone
        }

        return !window.isPlacedInZone
    }

    private func retargetDockMenusToActiveWindowIfNeeded(reason: String) {
        guard let destination = resolvedTriggeredTargetUsingActiveWindow(),
              destination != targetedZoneManager.targetedDestination else {
            return
        }

        applyTargetedDestination(destination, reason: reason)
    }
}
