/// WinShot snapshot creation, chooser UI, and restoration integration
import AppKit

extension AppController {
    // MARK: - Snapshot Creation

    /// Save a WinShot snapshot for the active screen (Control-Command-/)
    internal func saveWinShotSnapshot() {
        let screenId = activeScreenId()
        createWinShotSnapshot(on: screenId, reason: "user-save")
    }

    /// Create a WinShot snapshot for the specified screen if eligible
    @discardableResult
    internal func createWinShotSnapshot(on screenId: CGDirectDisplayID, reason: String) -> WinShotSnapshot? {
        guard let context = screenContexts[screenId] else {
            Logger.debug("WinShot: Cannot create snapshot - no context for screen \(screenId)")
            return nil
        }

        // Get temporary zone occupant for this screen
        let tempOccupant = temporaryZoneCoordinator.occupant(on: screenId)

        // Determine active window ID
        let activeWindowId = resolveActiveWindowId(on: screenId)

        return winShotManager.createSnapshot(
            screenId: screenId,
            zoneController: context.zoneController,
            windowController: windowController,
            temporaryZoneOccupant: tempOccupant,
            activeWindowId: activeWindowId,
            reason: reason
        )
    }

    /// Check if the screen has managed windows in zones (excluding placeholders)
    internal func screenHasWindowsInZones(_ screenId: CGDirectDisplayID) -> Bool {
        guard let context = screenContexts[screenId] else {
            return false
        }

        let zones = context.zoneController.allZones
        for zone in zones {
            if let windowId = zone.windowId,
               let managed = windowController.window(withId: windowId),
               !managed.isPlaceholder {
                return true
            }
        }

        // Also check temporary zone
        if temporaryZoneCoordinator.occupant(on: screenId) != nil {
            return true
        }

        return false
    }

    // MARK: - Chooser UI

    /// Show the WinShot chooser for the active screen (Control-Command-Tab)
    internal func showWinShotChooser() {
        let screenId = activeScreenId()
        let snapshots = winShotManager.snapshots(for: screenId)

        guard !snapshots.isEmpty else {
            Logger.debug("WinShot: No snapshots available for screen \(screenId)")
            return
        }

        winShotChooserController.show(snapshots: snapshots, on: screenId)
    }

    // MARK: - Snapshot Restoration

    /// Restore a WinShot snapshot
    internal func restoreWinShotSnapshot(_ snapshot: WinShotSnapshot) {
        let screenId = snapshot.screenId

        guard let context = screenContexts[screenId] else {
            Logger.debug("WinShot: Cannot restore - no context for screen \(screenId)")
            return
        }

        Logger.debug("WinShot: Restoring snapshot \(snapshot.id) on screen \(screenId)")

        // Step 1: Identify current windows on this screen (excluding placeholders)
        let currentWindows = collectCurrentWindows(on: screenId)

        // Step 2: Identify which windows are in the snapshot
        let snapshotWindowIds = snapshot.allWindowIds

        // Step 3: Find windows to minimize (current but not in snapshot)
        let windowsToMinimize = currentWindows.filter { !snapshotWindowIds.contains($0.windowId) }

        // Step 4: Restore zone configuration
        restoreZoneConfiguration(snapshot: snapshot, context: context)

        // Step 5: Restore windows in zones (unminimize if needed, position before unminimizing)
        for (zoneIndex, identity) in snapshot.zoneAssignments {
            restoreWindowToZone(identity: identity, zoneIndex: zoneIndex, on: screenId, context: context)
        }

        // Step 6: Restore temporary zone occupant
        if let tempIdentity = snapshot.temporaryZoneOccupant {
            restoreWindowToTemporaryZone(identity: tempIdentity, on: screenId)
        }

        // Step 7: Minimize windows that were not in the snapshot
        for window in windowsToMinimize {
            minimizeWindowProgrammatically(window, reason: "winshot-restore")
        }

        // Step 8: Sync and refresh
        syncWindowsToZones()
        refreshIndicators()

        // Step 9: Activate the previously active window
        if let activeWindowId = snapshot.activeWindowId,
           let activeWindow = windowController.window(withId: activeWindowId) {
            activateWindow(activeWindow)
        }

        Logger.debug("WinShot: Snapshot restoration complete")
    }

    // MARK: - Private Helpers

    private func resolveActiveWindowId(on screenId: CGDirectDisplayID) -> Int? {
        // Check frontmost application
        if let (managed, _) = managedWindowForFrontmostApplication(logPrefix: "WinShot activeWindow"),
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            return managed.windowId
        }

        // Fall back to last active pid
        if let lastPid = lastActiveApplicationPid,
           let managed = windowController.focusedWindowIfTracked(pid: lastPid),
           !managed.isPlaceholder,
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            return managed.windowId
        }

        return nil
    }

    private func collectCurrentWindows(on screenId: CGDirectDisplayID) -> [ManagedWindow] {
        var windows: [ManagedWindow] = []

        // Collect windows in zones
        if let context = screenContexts[screenId] {
            for zone in context.zoneController.allZones {
                if let windowId = zone.windowId,
                   let managed = windowController.window(withId: windowId),
                   !managed.isPlaceholder {
                    windows.append(managed)
                }
            }
        }

        // Collect temporary zone occupant
        if let tempOccupant = temporaryZoneCoordinator.occupant(on: screenId) {
            windows.append(tempOccupant)
        }

        return windows
    }

    private func restoreZoneConfiguration(snapshot: WinShotSnapshot, context: ScreenContext) {
        let currentZoneCount = context.zoneController.allZones.count
        let targetZoneCount = snapshot.zoneCount

        if currentZoneCount != targetZoneCount {
            context.zoneController.setZoneCount(to: targetZoneCount)
            placeholderCoordinator.clearMappingsForScreen(snapshot.screenId)
        }

        // Restore zone frames if stored
        // Note: For now we just restore zone count - exact frame ratios could be restored later
    }

    private func restoreWindowToZone(identity: WindowIdentity, zoneIndex: Int, on screenId: CGDirectDisplayID, context: ScreenContext) {
        // Find the window matching this identity
        guard let managed = findWindowMatching(identity: identity) else {
            Logger.debug("WinShot: Cannot find window for identity \(identity.windowId) in zone \(zoneIndex)")
            return
        }

        guard let zone = context.zoneController.zone(at: zoneIndex),
              let descriptor = descriptor(for: screenId) else {
            return
        }

        // First, remove the window from any zone it's currently in (could be on another screen)
        // This ensures the old zone gets a placeholder on syncWindowsToZones()
        for (otherScreenId, otherContext) in screenContexts {
            if otherContext.zoneController.zoneForWindow(windowId: managed.windowId) != nil {
                Logger.debug("WinShot: Removing window \(managed.windowId) from zone on screen \(otherScreenId) before restore")
                otherContext.zoneController.removeWindow(windowId: managed.windowId)
            }
        }

        // Also clear from any temporary zone it might be in
        if isWindowInTemporaryZone(managed.windowId) {
            clearTemporaryZone(for: managed.windowId, minimize: false, reason: "winshot-restore")
        }

        // If minimized, pre-position before unminimizing
        if managed.isMinimized {
            let targetFrame = frameWithMargin(for: zone, in: context.zoneController)
            prePositionMinimizedWindow(managed, to: targetFrame, on: descriptor)
            windowController.unminimizeWindow(managed)
        }

        // Assign to zone
        context.zoneController.assignWindow(windowId: managed.windowId, toZoneIndex: zoneIndex)
        setManagedWindow(managed, screenId: screenId, zoneIndex: zoneIndex)

        // Position window
        let targetFrame = frameWithMargin(for: zone, in: context.zoneController)
        windowController.moveWindow(managed, to: targetFrame, on: descriptor)
    }

    private func restoreWindowToTemporaryZone(identity: WindowIdentity, on screenId: CGDirectDisplayID) {
        guard let managed = findWindowMatching(identity: identity) else {
            Logger.debug("WinShot: Cannot find window for temporary zone identity \(identity.windowId)")
            return
        }

        // First, remove the window from any zone it's currently in (could be on another screen)
        // This ensures the old zone gets a placeholder on syncWindowsToZones()
        for (otherScreenId, otherContext) in screenContexts {
            if otherContext.zoneController.zoneForWindow(windowId: managed.windowId) != nil {
                Logger.debug("WinShot: Removing window \(managed.windowId) from zone on screen \(otherScreenId) before restore to temporary")
                otherContext.zoneController.removeWindow(windowId: managed.windowId)
            }
        }

        // Also clear from any temporary zone it might be in (on any screen)
        if isWindowInTemporaryZone(managed.windowId) {
            clearTemporaryZone(for: managed.windowId, minimize: false, reason: "winshot-restore")
        }

        // If minimized, unminimize first
        if managed.isMinimized {
            windowController.unminimizeWindow(managed)
        }

        // Assign to temporary zone
        temporaryZoneCoordinator.assign(managed, to: screenId, centerWindow: true, reason: "winshot-restore")
    }

    private func findWindowMatching(identity: WindowIdentity) -> ManagedWindow? {
        // Try to find by identity matching
        for window in windowController.allWindows {
            if identity.matches(window) {
                return window
            }
        }
        return nil
    }

    private func prePositionMinimizedWindow(_ managed: ManagedWindow, to screenFrame: CGRect, on screen: ScreenDescriptor) {
        // Pre-position the window while minimized for smooth animation
        // Convert from screen-local coordinates to accessibility coordinates
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
    }

    private func activateWindow(_ managed: ManagedWindow) {
        switch managed.backing {
        case .accessibility(let element, let pid, _):
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
            }
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        case .appKit(let window):
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - WinShotChooserControllerDelegate

extension AppController: WinShotChooserControllerDelegate {
    func chooserController(_ controller: WinShotChooserController, didSelect snapshotId: UUID) {
        guard let snapshot = winShotManager.snapshot(withId: snapshotId) else {
            Logger.debug("WinShot: Selected snapshot \(snapshotId) not found")
            return
        }

        restoreWinShotSnapshot(snapshot)
    }

    func chooserController(_ controller: WinShotChooserController, didRequestDelete snapshotId: UUID) {
        winShotManager.deleteSnapshot(snapshotId)
        Logger.debug("WinShot: Deleted snapshot \(snapshotId)")

        // Refresh the chooser if still active
        if controller.isActive,
           let screenId = screenContexts.keys.first(where: { winShotManager.hasSnapshots(for: $0) }) {
            let snapshots = winShotManager.snapshots(for: screenId)
            if !snapshots.isEmpty {
                controller.show(snapshots: snapshots, on: screenId)
            }
        }
    }

    func chooserControllerDidCancel(_ controller: WinShotChooserController) {
        Logger.debug("WinShot: Chooser cancelled")
    }
}
