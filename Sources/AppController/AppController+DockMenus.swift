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

        guard let managedWindowId = window.managedWindowId,
              let managed = windowController.window(withId: managedWindowId) else {
            Logger.debug("DockMenus: cannot begin drag - window not managed")
            return
        }

        // Determine origin zone
        let originZoneKey = zoneKey(forManagedWindow: managed)
        let originScreenId = detectScreenId(for: managed)
        let originatedFromFloating = isWindowInFloatingZone(managed.windowId)

        // Start cursor-driven drag session via DragDropCoordinator
        dragDropCoordinator.beginCursorDrivenDragSession(
            windowId: managedWindowId,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            originatedFromFloating: originatedFromFloating
        )
    }

    func dockMenusCoordinatorDidUpdateDrag(_ coordinator: DockMenusCoordinator, cursorPointAX: CGPoint?) {
        // Update the cursor-driven drag session
        dragDropCoordinator.updateCursorDrivenDragSession(cursorPointAX: cursorPointAX)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForWindow window: LauncherWindowItem, cursorPointAX: CGPoint?) {
        Logger.debug("DockMenus: drag ended for window \(window.title)")

        // Get the drop target from DragDropCoordinator
        let dropTarget = dragDropCoordinator.endCursorDrivenDragSession(cursorPointAX: cursorPointAX)

        // Perform placement based on drop target
        performDockMenuDrop(for: window, target: dropTarget)
    }

    private func performDockMenuDrop(for window: LauncherWindowItem, target: DragDropCoordinator.CursorDrivenDropTarget) {
        switch target {
        case .tilingZone(let zoneKey):
            placeDockMenuWindowIntoZone(window, zoneKey: zoneKey)

        case .floatingZone(let screenId):
            placeDockMenuWindowIntoFloatingZone(window, screenId: screenId)

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
        if !managed.isPlacedInZone {
            prePositionMinimizedWindowForDockMenuDrag(managed, to: displayFrame, on: descriptor)
            suppressNextEvents(for: [managed.windowId], events: [.deminiaturized], reason: "dockmenu-drag-unminimize")
            windowController.unminimizeWindow(managed)
        }

        // Place in target zone using shared logic
        placeWindowIntoZone(managed, zoneKey: zoneKey)
    }

    private func placeDockMenuWindowIntoFloatingZone(_ window: LauncherWindowItem, screenId: CGDirectDisplayID) {
        guard let managedWindowId = window.managedWindowId,
              let managed = windowController.window(withId: managedWindowId) else {
            Logger.debug("DockMenus: cannot place into floating zone - window not managed")
            return
        }

        // Unminimize if needed
        if !managed.isPlacedInZone {
            suppressNextEvents(for: [managed.windowId], events: [.deminiaturized], reason: "dockmenu-drag-unminimize")
            windowController.unminimizeWindow(managed)
        }

        // Remove from current zone first
        removeWindowFromAllZones(windowId: managed.windowId, reason: "dockmenu-drag", retarget: false)

        // Place in floating zone
        assignWindowToFloatingZone(managed, on: screenId, centerWindow: true, reason: "dockmenu-drag")
        Logger.debug("DockMenus: placed window \(managed.windowId) into floating zone on screen \(screenContextStore.loggingIndex(for: screenId))")

        syncWindowsToZones(recentlyPlacedInFloatingZone: managed.windowId)
        refreshIndicators()
    }

    private func placeDockMenuWindowIntoNewZone(_ window: LauncherWindowItem, screenId: CGDirectDisplayID) {
        guard window.managedWindowId != nil else {
            Logger.debug("DockMenus: cannot place into new zone - window not managed")
            return
        }

        guard let newZone = addZone(on: screenId, announce: false, promoteFloatingOccupant: false) else {
            Logger.debug("DockMenus: cannot add zone on screen \(screenContextStore.loggingIndex(for: screenId))")
            return
        }

        let newZoneKey = ZoneKey(screenId: screenId, index: newZone.index)

        // Place window into the new zone
        placeDockMenuWindowIntoZone(window, zoneKey: newZoneKey)
    }

    private func prePositionMinimizedWindowForDockMenuDrag(_ managed: ManagedWindow, to screenFrame: CGRect, on screen: ScreenDescriptor) {
        let effectiveScreenFrame = windowController.resolvedTargetScreenFrame(
            for: managed,
            requestedFrame: screenFrame,
            on: screen
        )
        let element = managed.backing.element
        let accessibilityFrame = screen.screenToAccessibility(effectiveScreenFrame)

        var position = accessibilityFrame.origin
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        }

        var size = accessibilityFrame.size
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }

        Logger.debug("DockMenus: pre-positioned minimized window \(managed.windowId) to \(effectiveScreenFrame) before unminimizing")
    }

    // MARK: - Non-Running App Drag-and-Drop

    func dockMenusCoordinatorDidBeginNonRunningAppDrag(_ coordinator: DockMenusCoordinator) {
        Logger.debug("DockMenus: non-running app drag began")
        // Start cursor-driven drag session without a windowId
        dragDropCoordinator.beginCursorDrivenDragSession(
            windowId: nil,
            originZoneKey: nil,
            originScreenId: nil
        )
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didEndDragForNonRunningApp appURL: URL, cursorPointAX: CGPoint?) {
        Logger.debug("DockMenus: non-running app drag ended for \(appURL.lastPathComponent)")

        let dropTarget = dragDropCoordinator.endCursorDrivenDragSession(cursorPointAX: cursorPointAX)

        switch dropTarget {
        case .tilingZone(let zoneKey):
            targetedZoneManager.setTargetedZone(zoneKey, reason: "dock-nonrunning-drag")
            launchApp(at: appURL)

        case .floatingZone(let screenId):
            targetedZoneManager.setFloatingTarget(on: screenId, reason: "dock-nonrunning-drag")
            launchApp(at: appURL)

        case .addZone(let screenId):
            if let newZone = addZone(on: screenId, announce: false, promoteFloatingOccupant: false) {
                let zoneKey = ZoneKey(screenId: screenId, index: newZone.index)
                targetedZoneManager.setTargetedZone(zoneKey, reason: "dock-nonrunning-drag")
            }
            launchApp(at: appURL)

        case .cancelled:
            Logger.debug("DockMenus: non-running app drag cancelled")
        }
    }

    private func launchApp(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error = error {
                Logger.debug("DockMenus: Failed to launch \(url.lastPathComponent): \(error.localizedDescription)")
            } else if let app = app {
                Logger.debug("DockMenus: Launched \(app.localizedName ?? url.lastPathComponent)")
            }
        }
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
