import AppKit
import ApplicationServices
import Foundation

/// DockMenus feature wiring and lifecycle management.
extension AppController {
    internal var isDockMenusEnabledInSettings: Bool {
        let config = effectiveDockMenusConfiguration()
        return config.isEnabled || config.showsDockFrameOverlay
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

    private func effectiveDockMenusConfiguration() -> DockMenusConfiguration {
        let baseConfig = configuration.dockMenusConfiguration
        guard let preferences = DockMenusPreferencesStore.loadPreferences() else {
            return baseConfig
        }

        return DockMenusConfiguration(
            enabled: preferences.enabled,
            debugDockFrameOverlay: nil
        )
    }

    private func applyDockMenusConfiguration() {
        stopDockMenus()
        startDockMenusIfConfigured()
    }
}

// MARK: - DockMenusCoordinatorDelegate

extension AppController: DockMenusCoordinatorDelegate {
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didClickDockAppWithURL appURL: URL) {
        Logger.debug("DockMenus: click on \(appURL.lastPathComponent)")
        // DockMenus uses activateInPlace:true - windows already in a zone are activated
        // without being moved to the targeted zone (unlike the Launcher)
        performDefaultLauncherAction(for: appURL, activateInPlace: true)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, windowsForBundleId bundleId: String) -> [LauncherWindowItem] {
        // Reuse the existing LauncherWindowProvider implementation
        return windowsForApp(bundleIdentifier: bundleId)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didSelectWindow window: LauncherWindowItem) {
        Logger.debug("DockMenus: window selected \(window.title)")
        // Reuse Launcher's window selection with activateInPlace semantics
        handleWindowSelection(window, activateInPlace: true)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didSelectAppHeader bundleId: String) {
        Logger.debug("DockMenus: app header selected for \(bundleId)")
        // Activate the app without targeting a specific window
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - Drag-and-Drop

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didBeginDragForWindow window: LauncherWindowItem) {
        Logger.debug("DockMenus: drag began for window \(window.title)")

        guard let managedWindowId = window.managedWindowId,
              let managed = windowController.window(withId: managedWindowId) else {
            Logger.debug("DockMenus: cannot begin drag - window not managed")
            return
        }

        // Determine origin zone
        let originZoneKey = zoneKey(forManagedWindow: managed)
        let originScreenId = detectScreenId(for: managed)
        let originatedFromTemporary = isWindowInTemporaryZone(managed.windowId)

        // Start cursor-driven drag session via DragDropCoordinator
        dragDropCoordinator.beginCursorDrivenDragSession(
            windowId: managedWindowId,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            originatedFromTemporary: originatedFromTemporary
        )
    }

    func dockMenusCoordinatorDidUpdateDrag(_ coordinator: DockMenusCoordinator) {
        // Update the cursor-driven drag session
        dragDropCoordinator.updateCursorDrivenDragSession()
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForWindow window: LauncherWindowItem) {
        Logger.debug("DockMenus: drag ended for window \(window.title)")

        // Get the drop target from DragDropCoordinator
        let dropTarget = dragDropCoordinator.endCursorDrivenDragSession()

        // Perform placement based on drop target
        performDockMenuDrop(for: window, target: dropTarget)
    }

    private func performDockMenuDrop(for window: LauncherWindowItem, target: DragDropCoordinator.CursorDrivenDropTarget) {
        switch target {
        case .tilingZone(let zoneKey):
            placeDockMenuWindowIntoZone(window, zoneKey: zoneKey)

        case .temporaryZone(let screenId):
            placeDockMenuWindowIntoTemporary(window, screenId: screenId)

        case .addZone(let screenId):
            placeDockMenuWindowIntoNewZone(window, screenId: screenId)

        case .cancelled:
            Logger.debug("DockMenus: drag cancelled, no placement")
        }
    }

    private func placeDockMenuWindowIntoZone(_ window: LauncherWindowItem, zoneKey: ZoneKey) {
        guard let managedWindowId = window.managedWindowId,
              let managed = windowController.window(withId: managedWindowId) else {
            Logger.debug("DockMenus: cannot place - window not managed")
            return
        }

        // Calculate target zone frame for pre-positioning
        guard let context = screenContexts[zoneKey.screenId],
              let descriptor = descriptor(for: zoneKey.screenId),
              let zone = context.zoneController.zone(at: zoneKey.index) else {
            Logger.debug("DockMenus: cannot place - zone not found")
            return
        }

        let displayFrame = frameWithMargin(for: zone, in: context.zoneController)

        // Unminimize if needed - pre-position BEFORE unminimizing for smooth animation
        if managed.isMinimized {
            prePositionMinimizedWindowForDockMenuDrag(managed, to: displayFrame, on: descriptor)
            suppressNextEvents(for: [managed.windowId], events: [.deminiaturized], reason: "dockmenu-drag-unminimize")
            windowController.unminimizeWindow(managed)
        }

        // Place in target zone using shared logic
        placeWindowIntoZone(managed, zoneKey: zoneKey)
    }

    private func placeDockMenuWindowIntoTemporary(_ window: LauncherWindowItem, screenId: CGDirectDisplayID) {
        guard let managedWindowId = window.managedWindowId,
              let managed = windowController.window(withId: managedWindowId) else {
            Logger.debug("DockMenus: cannot place into temporary - window not managed")
            return
        }

        // Unminimize if needed
        if managed.isMinimized {
            suppressNextEvents(for: [managed.windowId], events: [.deminiaturized], reason: "dockmenu-drag-unminimize")
            windowController.unminimizeWindow(managed)
        }

        // Remove from current zone first
        removeWindowFromAllZones(windowId: managed.windowId, reason: "dockmenu-drag", retarget: false)

        // Place in temporary zone
        assignWindowToTemporaryZone(managed, on: screenId, centerWindow: true, reason: "dockmenu-drag")
        Logger.debug("DockMenus: placed window \(managed.windowId) into temporary zone on screen \(screenId)")

        syncWindowsToZones()
        refreshIndicators()
    }

    private func placeDockMenuWindowIntoNewZone(_ window: LauncherWindowItem, screenId: CGDirectDisplayID) {
        guard window.managedWindowId != nil else {
            Logger.debug("DockMenus: cannot place into new zone - window not managed")
            return
        }

        // Add new zone (without promoting temporary occupant since we're dropping into it)
        guard let newZone = addZone(on: screenId, announce: false, promoteTemporaryOccupant: false) else {
            Logger.debug("DockMenus: cannot add zone on screen \(screenId)")
            return
        }

        let newZoneKey = ZoneKey(screenId: screenId, index: newZone.index)

        // Place window into the new zone
        placeDockMenuWindowIntoZone(window, zoneKey: newZoneKey)
    }

    private func prePositionMinimizedWindowForDockMenuDrag(_ managed: ManagedWindow, to screenFrame: CGRect, on screen: ScreenDescriptor) {
        guard case .accessibility(let element, _, _) = managed.backing else { return }

        let accessibilityFrame = screen.screenToAccessibility(screenFrame)

        var position = accessibilityFrame.origin
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        }

        var size = accessibilityFrame.size
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }

        Logger.debug("DockMenus: pre-positioned minimized window \(managed.windowId) to \(screenFrame) before unminimizing")
    }
}
