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
        let element = preferredManaged.backing.element
        let pid = preferredManaged.backing.pid

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Window"

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
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - Drag-and-Drop

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didBeginDragForWindow window: LauncherWindowItem) {
        Logger.debug("DockMenus: drag began for window \(window.title)")
        _ = beginCursorDrivenWindowDrag(for: window)
    }

    func dockMenusCoordinatorDidUpdateDrag(_ coordinator: DockMenusCoordinator, cursorPointAX: CGPoint?) {
        // Update the cursor-driven drag session
        dragDropCoordinator.updateCursorDrivenDragSession(cursorPointAX: cursorPointAX)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForWindow window: LauncherWindowItem, cursorPointAX: CGPoint?) {
        Logger.debug("DockMenus: drag ended for window \(window.title)")
        _ = performCursorDrivenManagedWindowDrop(
            for: window,
            cursorPointAX: cursorPointAX,
            reason: "dockmenu-drag"
        )
    }

    // MARK: - Non-Running App Drag-and-Drop

    func dockMenusCoordinatorDidBeginNonRunningAppDrag(_ coordinator: DockMenusCoordinator) {
        Logger.debug("DockMenus: non-running app drag began")
        beginCursorDrivenLaunchTargetDrag()
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForNonRunningApp appURL: URL, cursorPointAX: CGPoint?) {
        Logger.debug("DockMenus: non-running app drag ended for \(appURL.lastPathComponent)")
        _ = performCursorDrivenAppDrop(
            for: appURL,
            cursorPointAX: cursorPointAX,
            reason: "dock-nonrunning-drag"
        )
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
