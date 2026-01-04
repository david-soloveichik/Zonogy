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

        let snapshot = winShotManager.createSnapshot(
            screenId: screenId,
            zoneController: context.zoneController,
            windowController: windowController,
            screenDescriptor: context.descriptor,
            temporaryZoneOccupant: tempOccupant,
            activeWindowId: activeWindowId,
            reason: reason
        )

        // Refresh the WinShot chooser if it's open for this screen
        if snapshot != nil {
            refreshWinShotChooserIfNeeded(for: screenId)
        }

        return snapshot
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
        // If the chooser is already active, treat another shortcut press as "next"
        if winShotChooserController.isActive {
            winShotChooserController.cycleNext()
            return
        }

        let screenId = activeScreenId()
        let snapshots = winShotManager.snapshots(for: screenId)

        guard !snapshots.isEmpty else {
            Logger.debug("WinShot: No snapshots available for screen \(screenId)")
            return
        }

        winShotChooserController.show(snapshots: snapshots, on: screenId)
    }

    /// Refresh the WinShot chooser if it's currently open for the given screen
    internal func refreshWinShotChooserIfNeeded(for screenId: CGDirectDisplayID) {
        guard winShotChooserController.isActive,
              winShotChooserController.currentScreenId == screenId else {
            return
        }

        let snapshots = winShotManager.snapshots(for: screenId)
        winShotChooserController.refreshSnapshots(snapshots)
    }

    // MARK: - Snapshot Restoration

    /// Work item for restoring a window to a zone
    private struct ZoneRestoreWorkItem {
        let managed: ManagedWindow
        let zoneIndex: Int
        let zone: Zone
        let descriptor: ScreenDescriptor
        let targetFrame: CGRect
        let wasMinimized: Bool
    }

    /// Work item for restoring a window to the temporary zone
    private struct TemporaryRestoreWorkItem {
        let managed: ManagedWindow
        let wasMinimized: Bool
        let targetFrame: CGRect?
        let descriptor: ScreenDescriptor
    }

    /// Restore a WinShot snapshot with parallel window operations
    internal func restoreWinShotSnapshot(_ snapshot: WinShotSnapshot) {
        let screenId = snapshot.screenId

        guard let context = screenContexts[screenId] else {
            Logger.debug("WinShot: Cannot restore - no context for screen \(screenId)")
            return
        }

        guard let descriptor = descriptor(for: screenId) else {
            Logger.debug("WinShot: Cannot restore - no descriptor for screen \(screenId)")
            return
        }

        // Ensure the Launcher doesn't steal focus/cover restored windows mid-restore.
        if launcherController.isActive {
            launcherController.hide()
        }

        // Auto-save current state before restoring, so user can return to it later.
        // Only create if current windows differ from target snapshot to avoid
        // the deduplication logic deleting our target snapshot.
        let currentWindowIds = Set(collectCurrentWindows(on: screenId).map { $0.windowId })
        if currentWindowIds != snapshot.allWindowIds {
            createWinShotSnapshot(on: screenId, reason: "pre-restore")
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

        // Step 5: MINIMIZE PHASE - Minimize windows not in snapshot FIRST
        // This must happen before unminimizing new windows to avoid the old windows
        // briefly popping up in front of the new ones during minimize animation.
        for window in windowsToMinimize {
            minimizeWindowProgrammatically(window, reason: "winshot-restore")
            // Explicitly remove the window from all zones (and any temporary zone)
            // so that zones which are empty in the snapshot end up truly empty,
            // allowing placeholders to be restored correctly.
            removeWindowFromAllZones(windowId: window.windowId, reason: "winshot-restore", retarget: false)
        }

        // Step 6: PREP PHASE - Prepare all work items (find windows, remove from old locations)
        var zoneWorkItems: [ZoneRestoreWorkItem] = []
        var temporaryWorkItem: TemporaryRestoreWorkItem?

        // Prepare zone restoration work items
        for (zoneIndex, identity) in snapshot.zoneAssignments {
            if let workItem = prepareZoneRestore(
                identity: identity,
                zoneIndex: zoneIndex,
                on: screenId,
                context: context,
                descriptor: descriptor
            ) {
                zoneWorkItems.append(workItem)
            }
        }

        // Prepare temporary zone work item
        if let tempIdentity = snapshot.temporaryZoneOccupant {
            temporaryWorkItem = prepareTemporaryZoneRestore(
                identity: tempIdentity,
                targetFrame: snapshot.temporaryZoneFrame,
                on: screenId,
                descriptor: descriptor
            )
        }

        let restoredActiveWindowId = snapshot.activeWindowId
        let suppressRaiseDuringUnminimize = restoredActiveWindowId != nil

        // Step 6: UNMINIMIZE PHASE - Pre-position and unminimize tiled zone windows.
        // Suppress deminiaturize notifications to prevent re-placement loops.
        let minimizedZoneWindowIds = zoneWorkItems.filter { $0.wasMinimized }.map { $0.managed.windowId }
        if !minimizedZoneWindowIds.isEmpty {
            suppressNextEvents(for: minimizedZoneWindowIds, events: [.deminiaturized], reason: "winshot-restore")
        }
        for workItem in zoneWorkItems where workItem.wasMinimized {
            prePositionMinimizedWindow(workItem.managed, to: workItem.targetFrame, on: workItem.descriptor)
            let shouldRaise = !suppressRaiseDuringUnminimize || workItem.managed.windowId == restoredActiveWindowId
            windowController.unminimizeWindow(workItem.managed, raise: shouldRaise)
        }

        // Step 6b: ActiveFit coordination.
        // Schedule ActiveFit suppression BEFORE assignment to prevent assignment from triggering ActiveFit.
        // After the restore settles, ActiveFit will re-evaluate reveal/rest mode for the active zone window.
        let zoneWindowIds = zoneWorkItems.map { $0.managed.windowId }
        let activeZoneWindowId: Int? = {
            guard let activeId = snapshot.activeWindowId,
                  zoneWindowIds.contains(activeId) else {
                return nil
            }
            return activeId
        }()
        if !zoneWindowIds.isEmpty {
            scheduleActiveFitSuppression(windowIds: zoneWindowIds, evaluateRevealModeFor: activeZoneWindowId)
        }

        // Step 7: ASSIGNMENT PHASE - Assign tiled windows to their zones
        for workItem in zoneWorkItems {
            context.zoneController.assignWindow(windowId: workItem.managed.windowId, toZoneIndex: workItem.zoneIndex)
            setManagedWindow(workItem.managed, screenId: screenId, zoneIndex: workItem.zoneIndex)
        }

        // Step 8: POSITION PHASE - Move tiled windows to their target frames
        for workItem in zoneWorkItems {
            windowController.moveWindow(workItem.managed, to: workItem.targetFrame, on: workItem.descriptor)
        }

        // Step 9: Sync and refresh
        syncWindowsToZones()
        refreshIndicators()

        // Step 10: TEMPORARY ZONE RESTORATION - Restore last so it ends up on top and active
        if let tempItem = temporaryWorkItem {
            // Unminimize if needed
            if tempItem.wasMinimized {
                suppressNextEvents(for: [tempItem.managed.windowId], events: [.deminiaturized], reason: "winshot-restore")
                if let targetFrame = tempItem.targetFrame {
                    prePositionMinimizedWindow(tempItem.managed, to: targetFrame, on: tempItem.descriptor)
                }
                let shouldRaise = !suppressRaiseDuringUnminimize || tempItem.managed.windowId == restoredActiveWindowId
                windowController.unminimizeWindow(tempItem.managed, raise: shouldRaise)
            }

            // Assign to temporary zone (only center if no stored frame)
            let hasStoredFrame = tempItem.targetFrame != nil
            assignWindowToTemporaryZone(
                tempItem.managed,
                on: screenId,
                centerWindow: !hasStoredFrame,
                reason: "winshot-restore"
            )

            // Position to stored frame
            if let targetFrame = tempItem.targetFrame {
                windowController.moveWindow(tempItem.managed, to: targetFrame, on: tempItem.descriptor)
            }

            scheduleTemporaryZoneProtection(windowId: tempItem.managed.windowId)
        }

        // Step 11: Activate the previously active window
        snapshot.logDebugDetails(context: "restoring")
        if let activeWindowId = snapshot.activeWindowId,
           let activeWindow = windowController.window(withId: activeWindowId) {
            activateWindow(activeWindow)
        }

        Logger.debug("WinShot: Snapshot restoration complete")
    }

    /// Prepare a zone restoration work item (does all prep work, returns nil if window not found)
    private func prepareZoneRestore(
        identity: WindowIdentity,
        zoneIndex: Int,
        on screenId: CGDirectDisplayID,
        context: ScreenContext,
        descriptor: ScreenDescriptor
    ) -> ZoneRestoreWorkItem? {
        // Find the window matching this identity
        guard let managed = findWindowMatching(identity: identity) else {
            Logger.debug("WinShot: Cannot find window for identity \(identity.windowId) in zone \(zoneIndex)")
            return nil
        }

        guard let zone = context.zoneController.zone(at: zoneIndex) else {
            return nil
        }

        // Remove the window from any zone it's currently in (could be on another screen)
        for (otherScreenId, otherContext) in screenContexts {
            if otherContext.zoneController.zoneForWindow(windowId: managed.windowId) != nil {
                Logger.debug("WinShot: Removing window \(managed.windowId) from zone on screen \(otherScreenId) before restore")
                otherContext.zoneController.removeWindow(windowId: managed.windowId)
            }
        }

        // Clear from any temporary zone
        if isWindowInTemporaryZone(managed.windowId) {
            clearTemporaryZone(for: managed.windowId, minimize: false, reason: "winshot-restore")
        }

        let targetFrame = frameWithMargin(for: zone, in: context.zoneController)

        return ZoneRestoreWorkItem(
            managed: managed,
            zoneIndex: zoneIndex,
            zone: zone,
            descriptor: descriptor,
            targetFrame: targetFrame,
            wasMinimized: managed.isMinimized
        )
    }

    /// Prepare a temporary zone restoration work item
    private func prepareTemporaryZoneRestore(
        identity: WindowIdentity,
        targetFrame: CGRect?,
        on screenId: CGDirectDisplayID,
        descriptor: ScreenDescriptor
    ) -> TemporaryRestoreWorkItem? {
        guard let managed = findWindowMatching(identity: identity) else {
            Logger.debug("WinShot: Cannot find window for temporary zone identity \(identity.windowId)")
            return nil
        }

        // Remove from any zone it's currently in
        for (otherScreenId, otherContext) in screenContexts {
            if otherContext.zoneController.zoneForWindow(windowId: managed.windowId) != nil {
                Logger.debug("WinShot: Removing window \(managed.windowId) from zone on screen \(otherScreenId) before restore to temporary")
                otherContext.zoneController.removeWindow(windowId: managed.windowId)
            }
        }

        // Clear from any temporary zone
        if isWindowInTemporaryZone(managed.windowId) {
            clearTemporaryZone(for: managed.windowId, minimize: false, reason: "winshot-restore")
        }

        return TemporaryRestoreWorkItem(
            managed: managed,
            wasMinimized: managed.isMinimized,
            targetFrame: targetFrame,
            descriptor: descriptor
        )
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

        // Restore zone frames/ratios
        // Resize zone 1 first (sets left width ratio), then zone 2 (sets height ratio for 3-zone layout)
        for zoneIndex in 1...targetZoneCount {
            if let savedFrame = snapshot.zoneFrames[zoneIndex] {
                context.zoneController.resizeZone(at: zoneIndex, to: savedFrame, allowOccupied: true)
            }
        }
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
        // Record activity immediately for reliable recency tracking (don't rely on AX notification)
        windowController.recordWindowActivity(windowId: managed.windowId)

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

        // Refresh the chooser if still active for the same screen
        if let screenId = controller.currentScreenId {
            refreshWinShotChooserIfNeeded(for: screenId)
        }
    }

    func chooserControllerDidCancel(_ controller: WinShotChooserController) {
        Logger.debug("WinShot: Chooser cancelled")
    }
}
