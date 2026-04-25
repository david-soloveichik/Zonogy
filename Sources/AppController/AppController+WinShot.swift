/// WinShot snapshot creation, chooser UI, and restoration integration
import AppKit

extension AppController {
    // MARK: - Settings

    internal var isWinShotEnabled: Bool {
        WinShotPreferencesStore.loadEnabled()
    }

    internal var isWinShotAutoSaveSnapshotsEnabled: Bool {
        WinShotPreferencesStore.loadAutoSaveSnapshots()
    }

    internal var winShotMaxSnapshotsStoredInSettings: Int {
        WinShotPreferencesStore.loadMaxSnapshotsStored()
    }

    internal func setWinShotEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("WinShot: settings updated enabled=\(enabled)")
        WinShotPreferencesStore.saveEnabled(enabled)
    }

    internal func setWinShotAutoSaveSnapshotsEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("WinShot: settings updated autoSaveSnapshots=\(enabled)")
        WinShotPreferencesStore.saveAutoSaveSnapshots(enabled)
    }

    internal func setWinShotMaxSnapshotsStoredFromSettings(_ value: Int) {
        let normalized = WinShotPreferencesStore.normalizedMaxSnapshotsStored(value)
        Logger.debug("WinShot: settings updated maxSnapshotsStored=\(normalized)")
        WinShotPreferencesStore.saveMaxSnapshotsStored(normalized)
        winShotManager.enforceConfiguredSnapshotLimit()

        if let chooserScreenId = winShotChooserController.currentScreenId {
            refreshWinShotChooserIfNeeded(for: chooserScreenId)
        }
    }

    // MARK: - Snapshot Creation

    /// Save a WinShot snapshot for the active screen (Control-Command-/)
    internal func saveWinShotSnapshot() {
        guard isWinShotEnabled else {
            Logger.debug("WinShot: save shortcut ignored (WinShot disabled)")
            return
        }
        let screenId = activeScreenId()
        createWinShotSnapshot(on: screenId, reason: "user-save")
    }

    /// Auto-save a pre-clear snapshot when the screen currently has managed windows.
    internal func autoSavePreClearWinShotSnapshotIfNeeded(on screenId: CGDirectDisplayID, clearReason: String) {
        guard isWinShotEnabled, isWinShotAutoSaveSnapshotsEnabled else {
            return
        }

        guard let context = screenContexts[screenId] else {
            return
        }

        let hasManagedWindows =
            context.zoneController.allZones.contains(where: { !$0.isEmpty }) ||
            floatingZoneCoordinator.occupant(on: screenId) != nil
        guard hasManagedWindows else {
            return
        }

        createWinShotSnapshot(on: screenId, reason: "clear-zones-\(clearReason)")
    }

    /// Create a WinShot snapshot for the specified screen if eligible
    @discardableResult
    internal func createWinShotSnapshot(on screenId: CGDirectDisplayID, reason: String) -> WinShotSnapshot? {
        guard let context = screenContexts[screenId] else {
            Logger.debug("WinShot: Cannot create snapshot - no context for \(screenContextStore.logDescription(for: screenId))")
            return nil
        }

        // Get floating zone occupant for this screen
        let floatingOccupant = floatingZoneCoordinator.occupant(on: screenId)

        // Determine active window ID.
        // When a floating zone occupant exists, always mark it as the active window so that
        // restoration brings it to the front (floating zone floats above the tiled layout).
        let activeWindowId = floatingOccupant?.windowId ?? resolveActiveWindowId(on: screenId)

        let snapshot = winShotManager.createSnapshot(
            screenId: screenId,
            zoneController: context.zoneController,
            windowController: windowController,
            screenDescriptor: context.descriptor,
            floatingZoneOccupant: floatingOccupant,
            rememberedStickyResizeSizesByWindowId: rememberedManualResizeSizesByWindowId,
            activeWindowId: activeWindowId,
            reason: reason
        )

        // Refresh the WinShot chooser if it's open for this screen
        if snapshot != nil {
            refreshWinShotChooserIfNeeded(for: screenId)
        }

        return snapshot
    }

    // MARK: - Chooser UI

    /// Show the WinShot chooser for the active screen (Control-Command-Tab)
    internal func showWinShotChooser() {
        guard isWinShotEnabled else {
            Logger.debug("WinShot: chooser shortcut ignored (WinShot disabled)")
            return
        }

        // If the chooser is already active, treat another shortcut press as "next"
        if winShotChooserController.isActive {
            winShotChooserController.cycleNext()
            return
        }

        let screenId = activeScreenId()
        let snapshots = winShotManager.snapshots(for: screenId)

        guard !snapshots.isEmpty else {
            Logger.debug("WinShot: No snapshots available for \(screenContextStore.logDescription(for: screenId))")
            return
        }

        let initialSelectedIndex: Int = {
            guard snapshots.count > 1 else {
                return 0
            }

            guard let currentOccupancySignature = currentSnapshotOccupancySignature(on: screenId) else {
                return 0
            }
            return WinShotChooserInitialSelectionPolicy.initialSelectedIndex(
                snapshotOccupancySignatures: snapshots.map { WinShotSnapshotOccupancySignature(snapshot: $0) },
                currentOccupancySignature: currentOccupancySignature
            )
        }()

        winShotChooserController.show(snapshots: snapshots, on: screenId)
        winShotChooserController.selectIndex(initialSelectedIndex)
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

    /// Work item for restoring a window to the floating zone
    private struct FloatingRestoreWorkItem {
        let managed: ManagedWindow
        let wasMinimized: Bool
        let targetFrame: CGRect?
        let descriptor: ScreenDescriptor
    }

    /// Restore a WinShot snapshot with parallel window operations
    internal func restoreWinShotSnapshot(_ snapshot: WinShotSnapshot) {
        let screenId = snapshot.screenId

        guard let context = screenContexts[screenId] else {
            Logger.debug("WinShot: Cannot restore - no context for \(screenContextStore.logDescription(for: screenId))")
            return
        }

        guard let descriptor = descriptor(for: screenId) else {
            Logger.debug("WinShot: Cannot restore - no descriptor for \(screenContextStore.logDescription(for: screenId))")
            return
        }

        // Restoring a snapshot implies re-entering managed tiling. Ensure UnderCovers is exited so
        // placeholders are not incorrectly suppressed after the restore.
        endUnderCovers(on: screenId, reason: "winshot-restore", recreatePlaceholders: false)

        // Ensure the Launcher doesn't steal focus/cover restored windows mid-restore.
        if launcherController.isActive {
            launcherController.hide()
        }

        // Suppress twitchy activity recording during restoration.
        // The explicitly restored active window will bypass this via direct recordWindowActivity call.
        scheduleActivityRecordingSuppression(reason: "winshot-restore")

        // Clear any stale pending re-raise from a previous restore whose notifications never arrived.
        pendingRestoreRaise = nil

        Logger.debug("WinShot: Restoring snapshot \(snapshot.id) on \(screenContextStore.logDescription(for: screenId))")

        // Step 1: Identify current windows on this screen (excluding placeholders)
        let currentWindows = collectCurrentWindows(on: screenId)

        // Step 2: Identify which windows are in the snapshot
        let snapshotWindowIds = snapshot.allWindowIds

        // Step 3: Find windows to minimize (current but not in snapshot)
        let windowsToMinimize = currentWindows.filter { !snapshotWindowIds.contains($0.windowId) }

        // Step 4: Restore zone configuration
        restoreZoneConfiguration(snapshot: snapshot, context: context)

        // Step 5: PREP PHASE - Prepare all work items (find windows, remove from old locations)
        var zoneWorkItems: [ZoneRestoreWorkItem] = []
        var floatingWorkItem: FloatingRestoreWorkItem?

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

        // Prepare floating zone work item
        if let floatingIdentity = snapshot.floatingZoneOccupant {
            floatingWorkItem = prepareFloatingZoneRestore(
                identity: floatingIdentity,
                targetFrame: snapshot.floatingZoneFrame,
                on: screenId,
                descriptor: descriptor
            )
        }

        restoreStickyResizeRememberedSizes(from: snapshot, zoneWorkItems: zoneWorkItems)

        let restoredActiveWindowId = snapshot.activeWindowId
        let suppressRaiseDuringUnminimize = restoredActiveWindowId != nil

        // Step 6: UNMINIMIZE PHASE - Pre-position and unminimize ALL windows (tiled + floating)
        // in parallel. Unminimizing first makes the UI feel faster since users see new windows
        // immediately. Suppress deminiaturize notifications to prevent re-placement loops.
        let minimizedZoneWindowIds = zoneWorkItems.filter { $0.wasMinimized }.map { $0.managed.windowId }
        var allMinimizedWindowIds = minimizedZoneWindowIds
        if let floatingItem = floatingWorkItem, floatingItem.wasMinimized {
            allMinimizedWindowIds.append(floatingItem.managed.windowId)
        }
        if !allMinimizedWindowIds.isEmpty {
            suppressNextEvents(for: allMinimizedWindowIds, events: [.deminiaturized], reason: "winshot-restore")
        }

        // Set up pending re-raise: when each non-active window's deminiaturize notification
        // arrives (suppressed), re-raise the active window so it stays in front.
        let nonActiveMinimizedIds = allMinimizedWindowIds.filter { $0 != restoredActiveWindowId }
        if !nonActiveMinimizedIds.isEmpty,
           let activeId = restoredActiveWindowId,
           let activeWindow = windowController.window(withId: activeId) {
            pendingRestoreRaise = PendingRestoreRaise(
                element: activeWindow.backing.element,
                pid: activeWindow.backing.pid,
                pendingWindowIds: Set(nonActiveMinimizedIds)
            )
        }

        for workItem in zoneWorkItems where workItem.wasMinimized {
            let shouldRaise = !suppressRaiseDuringUnminimize || workItem.managed.windowId == restoredActiveWindowId
            unminimizeWithPrePositioning(
                workItem.managed,
                targetFrame: workItem.targetFrame,
                on: workItem.descriptor,
                reason: "winshot-restore",
                suppressAXNotifications: true,
                raise: shouldRaise
            )
        }

        // Unminimize floating zone window in parallel with tiled windows
        if let floatingItem = floatingWorkItem, floatingItem.wasMinimized {
            let shouldRaise = !suppressRaiseDuringUnminimize || floatingItem.managed.windowId == restoredActiveWindowId
            unminimizeWithPrePositioning(
                floatingItem.managed,
                targetFrame: floatingItem.targetFrame,
                on: floatingItem.descriptor,
                reason: "winshot-restore",
                suppressAXNotifications: true,
                raise: shouldRaise
            )
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

        // Step 9: MINIMIZE PHASE - Minimize windows not in snapshot AFTER unminimizing tiled windows.
        // We must remove these windows before sync so placeholder creation sees the final empty zones.
        for window in windowsToMinimize {
            minimizeWindowProgrammatically(window, reason: "winshot-restore")
            // Explicitly remove the window from all zones (and any floating zone)
            // so that zones which are empty in the snapshot end up truly empty,
            // allowing placeholders to be restored correctly.
            removeWindowFromAllZones(windowId: window.windowId, reason: "winshot-restore", retarget: false)
        }

        // Step 9b: Verify minimization took effect. Some apps like Word seem to sometimes auto-activate
        // sibling windows when one is minimized, which can cancel a rapid-fire minimize.
        for window in windowsToMinimize {
            scheduleMinimizeVerification(
                windowId: window.windowId,
                emptiedZoneKey: nil,
                minimizeReason: "winshot-restore",
                cleanupReason: "winshot-restore",
                manualResizeState: ManualResizeCleanupState(wasDetached: false, rememberedSize: nil)
            )
        }

        // Step 10: Sync and refresh based on final tiling occupancy.
        syncWindowsToZones()
        refreshIndicators()

        // Step 11: FLOATING ZONE ASSIGNMENT - Assign and position the floating zone window.
        // Unminimization already happened in Step 6 (parallel with tiled windows).
        if let floatingItem = floatingWorkItem {
            let hasStoredFrame = floatingItem.targetFrame != nil
            assignWindowToFloatingZone(
                floatingItem.managed,
                on: screenId,
                centerWindow: !hasStoredFrame,
                reason: "winshot-restore"
            )

            if let targetFrame = floatingItem.targetFrame {
                windowController.moveWindow(floatingItem.managed, to: targetFrame, on: floatingItem.descriptor)
                // Override any stale seed from assign (which used pre-restore actualFrame)
                // so the remembered floating size matches the restored snapshot frame.
                floatingZoneCoordinator.rememberSize(for: floatingItem.managed.windowId, size: targetFrame.size)
            }

            scheduleFloatingZoneProtection(windowId: floatingItem.managed.windowId)
        }

        // Step 12: Activate the previously active window
        // Use the floating zone activation workaround if the active window is in the floating zone.
        snapshot.logDebugDetails(context: "restoring")
        if let activeWindowId = snapshot.activeWindowId,
           let activeWindow = windowController.window(withId: activeWindowId) {
            if floatingWorkItem?.managed.windowId == activeWindowId {
                activateFloatingZoneWindow(activeWindow, reason: "winshot-restore")
            } else {
                activateWindow(activeWindow)
                if let screenId = activeWindow.screenDisplayId ?? detectScreenId(for: activeWindow),
                   let zoneIndex = activeWindow.zoneIndex {
                    _ = applyRememberedStickyResizeFrameIfAvailable(
                        for: activeWindow,
                        screenId: screenId,
                        zoneIndex: zoneIndex,
                        reason: "winshot-restore-activate"
                    )
                }
            }
        }

        // Step 13: Update targeting after restore
        // If the targeted zone is on the restored screen, apply standard targeting rules.
        // If the targeted zone is on another screen, leave targeting as is.
        let targetOnRestoredScreen: Bool
        if let tiledKey = targetedZoneKey {
            targetOnRestoredScreen = tiledKey.screenId == screenId
        } else if let floatingScreenId = targetedFloatingScreenId {
            targetOnRestoredScreen = floatingScreenId == screenId
        } else {
            targetOnRestoredScreen = false
        }

        if targetOnRestoredScreen {
            // Apply standard targeting preference: lowest-index empty zone, or floating zone if all filled
            if let emptyZone = targetedZoneManager.lowestIndexEmptyZoneOnSameScreen(screenId: screenId, excluding: nil) {
                targetedZoneManager.setTargetedZone(emptyZone, reason: "winshot-restore")
            } else {
                targetedZoneManager.setFloatingTarget(on: screenId, reason: "winshot-restore")
            }
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
                Logger.debug("WinShot: Removing window \(managed.windowId) from zone on \(screenContextStore.logDescription(for: otherScreenId)) before restore")
                otherContext.zoneController.removeWindow(windowId: managed.windowId)
            }
        }

        // Clear from any floating zone
        if isWindowInFloatingZone(managed.windowId) {
            clearFloatingZone(for: managed.windowId, minimize: false, reason: "winshot-restore")
        }

        let targetFrame = frameWithMargin(for: zone, in: context.zoneController)

        return ZoneRestoreWorkItem(
            managed: managed,
            zoneIndex: zoneIndex,
            zone: zone,
            descriptor: descriptor,
            targetFrame: targetFrame,
            wasMinimized: managed.isMinimizedPerAccessibility
        )
    }

    /// Prepare a floating zone restoration work item
    private func prepareFloatingZoneRestore(
        identity: WindowIdentity,
        targetFrame: CGRect?,
        on screenId: CGDirectDisplayID,
        descriptor: ScreenDescriptor
    ) -> FloatingRestoreWorkItem? {
        guard let managed = findWindowMatching(identity: identity) else {
            Logger.debug("WinShot: Cannot find window for floating zone identity \(identity.windowId)")
            return nil
        }

        // Remove from any zone it's currently in
        for (otherScreenId, otherContext) in screenContexts {
            if otherContext.zoneController.zoneForWindow(windowId: managed.windowId) != nil {
                Logger.debug("WinShot: Removing window \(managed.windowId) from zone on \(screenContextStore.logDescription(for: otherScreenId)) before restore to floating zone")
                otherContext.zoneController.removeWindow(windowId: managed.windowId)
            }
        }

        // Clear from any floating zone
        if isWindowInFloatingZone(managed.windowId) {
            clearFloatingZone(for: managed.windowId, minimize: false, reason: "winshot-restore")
        }

        return FloatingRestoreWorkItem(
            managed: managed,
            wasMinimized: managed.isMinimizedPerAccessibility,
            targetFrame: targetFrame,
            descriptor: descriptor
        )
    }

    // MARK: - Private Helpers

    private func resolveActiveWindowId(on screenId: CGDirectDisplayID) -> Int? {
        let screenDescription = screenContextStore.logDescription(for: screenId)

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            let bundleId = frontmost.bundleIdentifier ?? "unknown"
            Logger.debug(
                "WinShot: Resolving active window id on \(screenDescription) (frontmost pid: \(frontmost.processIdentifier), bundle: \(bundleId))"
            )
        } else {
            Logger.debug("WinShot: Resolving active window id on \(screenDescription) (frontmost: nil)")
        }

        // Prefer the frontmost application's focused managed window.
        if let (managed, pid) = managedWindowForFrontmostApplication(logPrefix: "WinShot activeWindow") {
            let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
            if let managedScreenId, managedScreenId == screenId {
                Logger.debug("WinShot: Active window resolved to window \(managed.windowId) via frontmost pid \(pid) on \(screenDescription)")
                return managed.windowId
            }

            if let managedScreenId {
                let managedScreenDescription = screenContextStore.logDescription(for: managedScreenId)
                Logger.debug(
                    "WinShot: Frontmost focused window \(managed.windowId) (pid \(pid)) is on \(managedScreenDescription); expected \(screenDescription)"
                )
            } else {
                Logger.debug(
                    "WinShot: Frontmost focused window \(managed.windowId) (pid \(pid)) has no detectable screen; expected \(screenDescription)"
                )
            }
        } else {
            Logger.debug("WinShot: No tracked focused window for frontmost application while resolving active window on \(screenDescription)")
        }

        // Fall back to last active pid.
        guard let lastPid = lastActiveApplicationPid else {
            Logger.debug("WinShot: lastActiveApplicationPid is nil while resolving active window on \(screenDescription)")
            return nil
        }

        if let managed = windowController.focusedWindowIfTracked(pid: lastPid) {
            let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
            if let managedScreenId, managedScreenId == screenId {
                Logger.debug("WinShot: Active window resolved to window \(managed.windowId) via lastActiveApplicationPid \(lastPid) on \(screenDescription)")
                return managed.windowId
            }

            if let managedScreenId {
                let managedScreenDescription = screenContextStore.logDescription(for: managedScreenId)
                Logger.debug(
                    "WinShot: lastActiveApplicationPid \(lastPid) focused window \(managed.windowId) is on \(managedScreenDescription); expected \(screenDescription)"
                )
            } else {
                Logger.debug(
                    "WinShot: lastActiveApplicationPid \(lastPid) focused window \(managed.windowId) has no detectable screen; expected \(screenDescription)"
                )
            }
        } else {
            Logger.debug("WinShot: lastActiveApplicationPid \(lastPid) has no tracked focused window while resolving active window on \(screenDescription)")
        }

        Logger.debug("WinShot: Active window could not be resolved on \(screenDescription); snapshot activeWindowId will be nil")
        return nil
    }

    private func collectCurrentWindows(on screenId: CGDirectDisplayID) -> [ManagedWindow] {
        var windows: [ManagedWindow] = []

        // Collect windows in zones
        if let context = screenContexts[screenId] {
            for zone in context.zoneController.allZones {
                if let windowId = zone.occupantWindowId,
                   let managed = windowController.window(withId: windowId) {
                    windows.append(managed)
                }
            }
        }

        // Collect floating zone occupant
        if let floatingOccupant = floatingZoneCoordinator.occupant(on: screenId) {
            windows.append(floatingOccupant)
        }

        return windows
    }

    private func currentSnapshotOccupancySignature(on screenId: CGDirectDisplayID) -> WinShotSnapshotOccupancySignature? {
        guard let context = screenContexts[screenId] else {
            return nil
        }

        let zones = context.zoneController.allZones
        var tiledWindowIdsByZoneIndex: [Int: Int] = [:]

        for zone in zones {
            guard let windowId = zone.occupantWindowId,
                  windowController.window(withId: windowId) != nil else {
                continue
            }
            tiledWindowIdsByZoneIndex[zone.index] = windowId
        }

        return WinShotSnapshotOccupancySignature(
            presentZoneIndices: zones.map(\.index),
            tiledWindowIdsByZoneIndex: tiledWindowIdsByZoneIndex,
            floatingZoneWindowId: floatingZoneCoordinator.occupant(on: screenId)?.windowId
        )
    }

    private func restoreStickyResizeRememberedSizes(
        from snapshot: WinShotSnapshot,
        zoneWorkItems: [ZoneRestoreWorkItem]
    ) {
        guard stickyResizeEnabled,
              !snapshot.rememberedTiledWindowSizesByZoneIndex.isEmpty else {
            return
        }

        let restoredWindowIdsByZoneIndex = Dictionary(
            uniqueKeysWithValues: zoneWorkItems.map { ($0.zoneIndex, $0.managed.windowId) }
        )
        let restoredSizes = WinShotStickyResizeSnapshotMapping.restoredSizesByWindowId(
            snapshotSizesByZoneIndex: snapshot.rememberedTiledWindowSizesByZoneIndex,
            restoredWindowIdsByZoneIndex: restoredWindowIdsByZoneIndex
        )
        guard !restoredSizes.isEmpty else {
            return
        }

        for (windowId, size) in restoredSizes {
            rememberedManualResizeSizesByWindowId[windowId] = size
        }

        Logger.debug(
            "WinShot: restored Sticky Resize remembered sizes for windows \(restoredSizes.keys.sorted()) " +
            "from snapshot \(snapshot.id)"
        )
    }

    private func restoreZoneConfiguration(snapshot: WinShotSnapshot, context: ScreenContext) {
        clearRememberedManualResizeSizes(on: snapshot.screenId, reason: "winshot-restore-zone-config")

        let currentZoneCount = context.zoneController.allZones.count
        let targetZoneCount = snapshot.zoneCount

        if currentZoneCount != targetZoneCount {
            context.zoneController.setZoneCount(to: targetZoneCount)
            placeholderCoordinator.clearPlaceholdersForScreen(snapshot.screenId)
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
        // First pass: look for exact windowId match (highest confidence)
        for window in windowController.allWindows {
            if window.windowId == identity.windowId {
                return window
            }
        }

        // Second pass: fall back to fuzzy matching (externalIdentifier or bundle+title)
        // This potentially handles some edge cases where the app re-creates the window
        for window in windowController.allWindows {
            if identity.matches(window) {
                return window
            }
        }

        return nil
    }

    private func activateWindow(_ managed: ManagedWindow) {
        // Record activity immediately for reliable recency tracking (don't rely on AX notification)
        recordActiveWindowForHistory(windowId: managed.windowId, reason: "winshot-activate")
        raiseWindow(managed)
    }
}

// MARK: - WinShotChooserControllerDelegate

extension AppController: WinShotChooserControllerDelegate {
    func chooserController(_ controller: WinShotChooserController, didSelect snapshotId: UUID) {
        guard let snapshot = winShotManager.snapshot(withId: snapshotId) else {
            Logger.debug("WinShot: Selected snapshot \(snapshotId) not found")
            return
        }

        // Capture the same pre-clear auto-save snapshot that clear/reset would capture,
        // without running clear/reset UI behavior before restore.
        let screenId = snapshot.screenId
        autoSavePreClearWinShotSnapshotIfNeeded(on: screenId, clearReason: "winshot-chooser-switch")

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
