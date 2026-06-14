import Foundation
import AppKit
import ApplicationServices

/// Handles hotkeys, system events, and display reconfiguration.
extension AppController {
    internal func currentWindowCounts() -> (managed: Int, placeholders: Int) {
        (windowController.allWindows.count, placeholderCoordinator.activePlaceholderCount)
    }

    func hotkeyService(_ service: HotkeyService, didTrigger action: HotkeyService.Action) {
        // If WinShot chooser is active, dismiss it instead of triggering other actions.
        // Exception: showWinShotChooser cycles to the next snapshot (handled in showWinShotChooser()).
        if winShotChooserController.isActive && action != .showWinShotChooser {
            Logger.debug("Hotkey \(action) dismissed WinShot chooser")
            winShotChooserController.hide()
            return
        }

        switch action {
        case .addZone:
            Logger.debug("Hotkey add zone triggered")
        case .removeZone:
            Logger.debug("Hotkey remove zone triggered")
        case .collapseToOneZone:
            Logger.debug("Hotkey collapse to one zone triggered")
        case .captureTimeTravelLogs:
            Logger.debug("Hotkey capture time-travel logs triggered")
        case .clearOrResetZones:
            Logger.debug("Hotkey clear or reset zones triggered")
        case .clearOrResetZonesAtCursor:
            Logger.debug("Hotkey clear or reset zones at cursor triggered")
        case .targetFloatingZone:
            Logger.debug("Hotkey target floating zone triggered")
        case .targetTilingZone:
            Logger.debug("Hotkey target tiling zone triggered")
        case .navigateLeft:
            Logger.debug("Hotkey navigate left triggered")
        case .navigateRight:
            Logger.debug("Hotkey navigate right triggered")
        case .minimizeActiveWindow:
            Logger.debug("Hotkey minimize active window triggered")
        case .minimizeWindowOrRemoveZoneAtCursor:
            Logger.debug("Hotkey minimize window or remove zone at cursor triggered")
        case .saveWinShotSnapshot:
            Logger.debug("Hotkey save WinShot snapshot triggered")
        case .showWinShotChooser:
            Logger.debug("Hotkey show WinShot chooser triggered")
        case .showLauncher:
            Logger.debug("Hotkey show launcher triggered")
        case .focusTargetedWindow:
            Logger.debug("Hotkey focus targeted window triggered")
        case .toggleTargetZoneWithFocusedWindow:
            Logger.debug("Hotkey toggle target zone w/ focused window triggered")
        }
        triggerShortcut(action)
    }

    // MARK: - SystemEventMonitorDelegate

    func systemEventMonitor(_ monitor: SystemEventMonitor, handleKeyEvent event: NSEvent) -> Bool {
        hotkeyService.handleLocalShortcut(event: event)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didActivate application: NSRunningApplication?) {
        let appDescription = application.map { "\($0.localizedName ?? "Unknown"), pid \($0.processIdentifier), bundle \($0.bundleIdentifier ?? "nil")" } ?? "nil"
        Logger.debug("NSWorkspace notification received: didActivateApplication (\(appDescription))")
        if shouldIgnoreDueToSleepWake(event: "NSWorkspace.didActivateApplicationNotification") {
            return
        }
        if let previousPid = lastActiveApplicationPid {
            _ = validationRetryManager.validateWindowsForApplication(pid: previousPid, trigger: .workspaceActivationPreviousApp)
            handleManualResizeFocusChange(pid: previousPid, focusedWindowId: nil)
        }
        if let application {
            lastActiveApplicationPid = application.processIdentifier
        }
        handleApplicationEvent(application)

        // Sync the frontmost managed window and refresh resize handles on app activation.
        // AXFocusedWindowChanged notifications only fire when focus changes *within* an app,
        // not when the app itself is activated, so we can't rely on windowFocusChanged here.
        let focusedManagedWindow: ManagedWindow? = {
            guard let pid = application?.processIdentifier else {
                return nil
            }
            return windowController.focusedWindowIfTracked(pid: pid)
        }()
        if let applicationPid = application?.processIdentifier,
           let focusedManagedWindow {
            handleManualResizeFocusChange(pid: applicationPid, focusedWindowId: focusedManagedWindow.windowId)
        }
        handleActiveFitActivationCandidate(pid: application?.processIdentifier)
        handleFloatingZoneActivationChange(focusedPid: application?.processIdentifier, reason: "workspace-activate")
        updateUnmanagedFocusState()

        if focusedManagedWindow != nil {
            exitPinnedResizeBarMode(reason: "managed-window-activation")
        }
        setCurrentFrontmostManagedWindowId(focusedManagedWindow?.windowId, reason: "workspace-activate")
        refreshResizeHandles()

        // Record window activity for CmdTab recency tracking.
        // Skip during activity suppression to avoid twitchy recordings during floating zone/WinShot operations.
        if let applicationPid = application?.processIdentifier,
           let focusedManagedWindow,
           !isActivityRecordingSuppressed() {
            recordActiveWindowForHistoryDebounced(windowId: focusedManagedWindow.windowId, pid: applicationPid, reason: "workspace-activate")
        }

        // Record app activation for Launcher app recency ordering.
        // This is the single source of truth for app recency - triggered by NSWorkspace
        // didActivateApplicationNotification which fires for all app activations (Dock clicks,
        // Cmd-Tab, window clicks, Launcher, etc.) regardless of whether the app has windows.
        if let bundleId = application?.bundleIdentifier {
            LaunchItemUsageStore.shared.recordAppActivation(bundleIdentifier: bundleId)
        }
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didLaunch application: NSRunningApplication?) {
        let appDescription = application.map { "\($0.localizedName ?? "Unknown"), pid \($0.processIdentifier), bundle \($0.bundleIdentifier ?? "nil")" } ?? "nil"
        Logger.debug("NSWorkspace notification received: didLaunchApplication (\(appDescription))")
        if shouldIgnoreDueToSleepWake(event: "NSWorkspace.didLaunchApplicationNotification") {
            return
        }

        // Dismiss Launcher only when a manageable application launches
        if launcherController.isActive,
           let application,
           shouldManage(application: application) {
            launcherController.hide()
            Logger.debug("Launcher: Hidden because managed application launched")
        }

        handleApplicationEvent(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didUnhide application: NSRunningApplication?) {
        if shouldIgnoreDueToSleepWake(event: "NSWorkspace.didUnhideApplicationNotification") {
            return
        }
        handleApplicationEvent(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didDeactivate application: NSRunningApplication?) {
        if shouldIgnoreDueToSleepWake(event: "NSWorkspace.didDeactivateApplicationNotification") {
            return
        }
        handleApplicationStateChange(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didHide application: NSRunningApplication?) {
        if shouldIgnoreDueToSleepWake(event: "NSWorkspace.didHideApplicationNotification") {
            return
        }

        guard let application else { return }

        let pid = application.processIdentifier

        var hasManagedWindows = false
        var windowsToMinimize: [(ManagedWindow, ZoneKey?)] = []

        for window in windowController.allWindows {
            guard window.backing.pid == pid else {
                continue
            }

            hasManagedWindows = true
            if window.isPlacedInZone {
                windowsToMinimize.append((window, zoneKey(forManagedWindow: window)))
            }
        }

        // Only intercept hide for apps Zonogy manages
        guard hasManagedWindows else {
            // Let the hide happen normally for unmanaged apps
            handleApplicationStateChange(application)
            return
        }

        Logger.debug("Intercepting hide for \(application.localizedName ?? "Unknown") (pid \(pid))")

        // Unhide the app immediately - we convert hide to minimize
        application.unhide()

        if windowsToMinimize.isEmpty {
            Logger.debug("No unminimized windows to minimize for hidden app (pid \(pid))")
        } else {
            // Minimize all collected windows with proper cleanup
            for (window, emptiedZoneKey) in windowsToMinimize {
                let manualResizeState = performProgrammaticMinimizeCleanup(
                    window,
                    minimizeReason: "hide-to-minimize",
                    cleanupReason: "hide-to-minimize",
                    retarget: true
                )
                scheduleMinimizeVerification(
                    windowId: window.windowId,
                    emptiedZoneKey: emptiedZoneKey,
                    minimizeReason: "hide-to-minimize",
                    cleanupReason: "hide-to-minimize",
                    manualResizeState: manualResizeState
                )
            }

            syncWindowsToZones()
            Logger.debug("Converted hide to minimize for \(windowsToMinimize.count) window(s)")
        }

        // Still run destroyed-window validation (the original hide handler behavior)
        handleApplicationStateChange(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didTerminate application: NSRunningApplication?) {
        if shouldIgnoreDueToSleepWake(event: "NSWorkspace.didTerminateApplicationNotification") {
            return
        }
        handleApplicationTermination(application)
    }

    func systemEventMonitorActiveSpaceDidChange(_ monitor: SystemEventMonitor) {
        Logger.debug("NSWorkspace notification received: activeSpaceDidChange")
        if shouldIgnoreDueToSleepWake(event: "NSWorkspace.activeSpaceDidChangeNotification") {
            return
        }
        scheduleFullScreenRescanForSpaceChange()
    }

    func systemEventMonitorScreensDidSleep(_ monitor: SystemEventMonitor) {
        Logger.debug("SystemEventMonitor: NSWorkspace.screensDidSleepNotification received")
        handleScreensDidSleep()
    }

    func systemEventMonitorScreensDidWake(_ monitor: SystemEventMonitor) {
        Logger.debug("SystemEventMonitor: NSWorkspace.screensDidWakeNotification received")
        handleScreensDidWake()
    }

    func systemEventMonitorScreensDidChange(_ monitor: SystemEventMonitor) {
        if shouldIgnoreDueToSleepWake(event: "NSApplication.didChangeScreenParametersNotification") {
            return
        }
        Logger.debug("Screen configuration change notification received from AppKit")
        scheduleScreenTopologyRefresh(reason: "appkit-notification")
    }

    /// Updates `unmanagedFocusedWindowScreenId` based on the current frontmost window.
    /// If the focused window is confirmed unmanaged, stores its screen ID; otherwise clears the state.
    /// Calls `refreshResizeHandles()` when the state changes, and hides the Launcher if it's
    /// on the screen where an unmanaged window now has focus.
    internal func updateUnmanagedFocusState() {
        let previousScreenId = unmanagedFocusedWindowScreenId
        let resolution = resolveUnmanagedFocusState()
        let newScreenId: CGDirectDisplayID?

        switch resolution {
        case .managed(let window, let pid, let focusedElement):
            cancelUnmanagedFocusRetry()
            let focusedScreenId = window.screenDisplayId ?? detectScreenId(for: window)
            if let focusedScreenId {
                repairFullScreenPauseStateFromFocusedWindowIfNeeded(
                    focusedWindow: focusedElement,
                    pid: pid,
                    screenId: focusedScreenId,
                    reason: "managed-focus"
                )
            }
            newScreenId = nil
        case .managedUnknown:
            cancelUnmanagedFocusRetry()
            newScreenId = nil
        case .unmanaged(let screenId, let pid, let focusedElement, let reason):
            cancelUnmanagedFocusRetry()
            repairFullScreenPauseStateFromFocusedWindowIfNeeded(
                focusedWindow: focusedElement,
                pid: pid,
                screenId: screenId,
                reason: "unmanaged-focus-\(reason)"
            )
            newScreenId = screenId
        case .unresolved(let pid, let focusedElement, let reason):
            if reason == "window-appears-manageable",
               let focusedElement,
               let focusedScreenId = detectScreenId(for: focusedElement) {
                repairFullScreenPauseStateFromFocusedWindowIfNeeded(
                    focusedWindow: focusedElement,
                    pid: pid,
                    screenId: focusedScreenId,
                    reason: "unresolved-focus-\(reason)"
                )
            }
            scheduleUnmanagedFocusRetry(for: pid, reason: reason)
            newScreenId = nil
        }

        unmanagedFocusedWindowScreenId = newScreenId

        if previousScreenId != newScreenId {
            refreshResizeHandles()

            // Hide Launcher if it's on the screen where an unmanaged window now has focus
            if let newScreenId = newScreenId,
               launcherController.isActive,
               targetedScreenId() == newScreenId {
                if dismissLauncherIfActiveRespectingAutoShowGrace() {
                    Logger.debug("Launcher: Hidden because unmanaged window gained focus on screen \(screenContextStore.loggingIndex(for: newScreenId))")
                } else if launcherController.isInAutoShowGracePeriod {
                    Logger.debug("Launcher: Skipping hide for unmanaged focus during auto-show grace on screen \(screenContextStore.loggingIndex(for: newScreenId))")
                }
            }
        }
    }

    internal func cancelUnmanagedFocusRetry() {
        unmanagedFocusRetryState?.workItem?.cancel()
        unmanagedFocusRetryState = nil
    }

    private func scheduleUnmanagedFocusRetry(for pid: pid_t, reason: String) {
        guard !screensAsleep else {
            cancelUnmanagedFocusRetry()
            return
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            cancelUnmanagedFocusRetry()
            return
        }

        if unmanagedFocusRetryState?.pid != pid {
            cancelUnmanagedFocusRetry()
            unmanagedFocusRetryState = UnmanagedFocusRetryState(pid: pid, attempt: 0, workItem: nil)
        }

        guard var retry = unmanagedFocusRetryState else {
            return
        }

        if let workItem = retry.workItem, !workItem.isCancelled {
            return
        }

        guard retry.attempt < unmanagedFocusRetryDelays.count else {
            Logger.debug("Unmanaged focus retry exhausted for pid \(pid) after \(retry.attempt) attempts (reason: \(reason))")
            unmanagedFocusRetryState = nil
            return
        }

        let delay = unmanagedFocusRetryDelays[retry.attempt]
        let nextAttempt = retry.attempt + 1
        Logger.debug(
            "Scheduling unmanaged focus retry #\(nextAttempt) for pid \(pid) in \(String(format: "%.1f", delay))s (reason: \(reason))"
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.screensAsleep else {
                self.cancelUnmanagedFocusRetry()
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                self.cancelUnmanagedFocusRetry()
                return
            }

            self.unmanagedFocusRetryState?.workItem = nil
            self.unmanagedFocusRetryState?.attempt = nextAttempt
            Logger.debug("Executing unmanaged focus retry #\(nextAttempt) for pid \(pid)")
            self.updateUnmanagedFocusState()
        }

        retry.workItem = workItem
        unmanagedFocusRetryState = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - DisplayReconfigurationMonitorDelegate

    func displayMonitor(_ monitor: DisplayReconfigurationMonitor, didObserve event: DisplayReconfigurationMonitor.Event) {
        if shouldIgnoreDueToSleepWake(event: "CGDisplayReconfigurationCallback") {
            return
        }
        var components: [String] = []
        if event.isAdd { components.append("add") }
        if event.isRemove { components.append("remove") }
        if event.isMove { components.append("move") }
        if event.isEnabled { components.append("enabled") }
        if event.isDisabled { components.append("disabled") }
        if event.isConfigurationChange { components.append("config-change") }
        let description = components.isEmpty ? "unknown" : components.joined(separator: ",")
        Logger.debug("CGDisplay callback for id \(event.displayId) flags: \(description)")
        scheduleScreenTopologyRefresh(reason: "cgdisplay-\(description)", affectedDisplayIds: Set([event.displayId]))
    }

    private func suppressManualMoveHandling(for interval: TimeInterval, reason: String) {
        let newDeadline = Date().addingTimeInterval(interval)
        if manualMoveSuppressionDeadline == nil || newDeadline > manualMoveSuppressionDeadline! {
            manualMoveSuppressionDeadline = newDeadline
        }

        if dragDropCoordinator.isDragging {
            Logger.debug("Ending in-flight drag session due to manual move suppression (\(reason))")
            dragDropCoordinator.tearDownDragSession()
            syncWindowsToZones()
        }

        Logger.debug("Manual move handling suppressed for \(String(format: "%.2f", interval))s (reason: \(reason))")
    }

    internal func shouldSuppressManualMoveHandling(windowId: Int, event: String) -> Bool {
        guard let deadline = manualMoveSuppressionDeadline else {
            return false
        }
        if Date() < deadline {
            Logger.debug("Suppressed manual \(event) for window \(windowId) while displays stabilize")
            return true
        }
        manualMoveSuppressionDeadline = nil
        return false
    }

    internal func scheduleScreenTopologyRefresh(
        reason: String,
        affectedDisplayIds: Set<CGDirectDisplayID> = [],
        includesWake: Bool = false
    ) {
        suppressManualMoveHandling(for: manualMoveSuppressionDuration, reason: reason)
        if let existingReason = pendingScreenChangeReason {
            pendingScreenChangeReason = "\(existingReason),\(reason)"
        } else {
            pendingScreenChangeReason = reason
        }
        pendingScreenChangeIncludesWake = pendingScreenChangeIncludesWake || includesWake

        pendingScreenChangeDisplayIds.formUnion(affectedDisplayIds)

        pendingScreenChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let hintedIds = self.pendingScreenChangeDisplayIds
            let resolvedReason = self.pendingScreenChangeReason ?? reason
            let refreshIncludesWake = self.pendingScreenChangeIncludesWake
            self.pendingScreenChangeDisplayIds.removeAll()
            self.pendingScreenChangeReason = nil
            self.pendingScreenChangeIncludesWake = false
            self.performScreenTopologyRefresh(
                reason: resolvedReason,
                hintedDisplayIds: hintedIds,
                includesWake: refreshIncludesWake
            )
        }
        pendingScreenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + screenChangeDebounceInterval, execute: workItem)
    }

    private func performScreenTopologyRefresh(
        reason: String,
        hintedDisplayIds: Set<CGDirectDisplayID>,
        includesWake: Bool
    ) {
        Logger.debug("Performing screen topology refresh due to \(reason) (hinted display ids: \(hintedDisplayIds.count))")

        let screens = NSScreen.screens
        let rebuildResult = screenContextStore.rebuild(with: screens)

        // The primary display may have changed size/identity; fan the refreshed value out to every
        // subsystem that caches it for Cocoa<->Accessibility conversion (see helper below).
        refreshCachedPrimaryScreenBounds()

        if rebuildResult.addedDisplayIds.isEmpty,
           rebuildResult.removedContexts.isEmpty,
           rebuildResult.visibleFrameChangedDisplayIds.isEmpty,
           !rebuildResult.orderChanged {
            Logger.debug("Screen topology unchanged after refresh request (\(reason))")
        }

        if !rebuildResult.addedDisplayIds.isEmpty {
            Logger.debug("Detected new display ids: \(rebuildResult.addedDisplayIds)")
        }

        if !rebuildResult.removedContexts.isEmpty {
            let removedIds = rebuildResult.removedContexts.map { $0.displayId }
            Logger.debug("Detected removed display ids: \(removedIds)")
        }

        if !rebuildResult.visibleFrameChangedDisplayIds.isEmpty {
            Logger.debug("Active screen area changed: \(rebuildResult.visibleFrameChangedDisplayIds)")
            for screenId in rebuildResult.visibleFrameChangedDisplayIds {
                clearRememberedManualResizeSizes(on: screenId, reason: "screen-visible-frame-changed")
            }
        }

        if !rebuildResult.removedContexts.isEmpty {
            handleRemovedScreens(rebuildResult.removedContexts)
        }

        targetedZoneManager.ensureTargetedZone(reason: "screens-changed")

        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: "screens-changed")

        // Re-scan full-screen state after screen changes
        // Clear first, then scan all windows to re-detect current state
        fullScreenTracker.clearAllState()
        scanAllWindowsForFullScreenState()

        // Recapture after displays settle when meaningful changes occurred.
        // Always recapture after wake to catch windows that were deminiaturized or
        // created while events were suppressed during the sleep transition.
        if includesWake || !rebuildResult.addedDisplayIds.isEmpty || !rebuildResult.removedContexts.isEmpty || !rebuildResult.visibleFrameChangedDisplayIds.isEmpty || rebuildResult.orderChanged {
            let recaptureReason = includesWake ? "wake" : "screen-change"
            scheduleWindowRecapture(delay: 0.5, reason: recaptureReason)
            scheduleWindowRecapture(delay: 1.5, reason: recaptureReason)

            // The Dock rebuilds its accessibility hierarchy on wake / display reconfiguration, which
            // can leave Zonogy's cached Dock AX observer bound to a stale element (hover silently
            // stops producing DockMenus). Re-establish it so hover detection rebinds to the new tree.
            // See SPECIFICATION-DOCKMENUS.md "Accessibility API Workarounds".
            dockMenusCoordinator?.reestablishDockObserver(reason: recaptureReason)
        }
    }

    /// Refresh every cached primary-display bounds copy from the screen-context store after a
    /// topology change. The store (refreshed in `ScreenContextStore.rebuild`) is the single source
    /// of truth; this fans the new value out to subsystems that keep their own cached copy for
    /// Cocoa<->Accessibility conversion. Centralized so there is exactly one place to update when a
    /// subsystem starts caching the primary bounds — the primary display's height is the shared
    /// flip reference for every screen, so a stale copy mis-positions windows on all displays.
    private func refreshCachedPrimaryScreenBounds() {
        primaryScreenId = screenContextStore.primaryDisplayId
        primaryScreenBounds = screenContextStore.primaryScreenBounds
        windowController.primaryScreenBounds = primaryScreenBounds
        dockMenusCoordinator?.updatePrimaryScreenBounds(primaryScreenBounds)
        fullScreenDebugOverlay?.updatePrimaryScreenBounds(primaryScreenBounds)
    }

    private func handleRemovedScreens(_ removed: [ScreenContextStore.RebuildResult.RemovedContext]) {
        for entry in removed {
            let displayId = entry.displayId

            // Snapshot all windows that currently report this displayId.
            let windowsOnDisplay = windowController.allWindows.filter {
                $0.screenDisplayId == displayId
            }

            // Clear placeholders for this display and close the windows.
            placeholderCoordinator.clearPlaceholdersForScreen(displayId)

            let zoneCount = entry.context.zoneController.allZones.count
            Logger.debug("Handling removal of screen \(entry.context.descriptor.localizedName) [screen \(screenContextStore.loggingIndex(for: displayId))] with \(zoneCount) zone(s)")

            // Minimize every non-placeholder managed window that was on the removed display,
            // instead of reassigning it to another screen. We rely on the pre-snapshot
            // windowsOnDisplay so this is robust even if earlier syncs cleared
            // screenDisplayId for those windows.
            for managed in windowsOnDisplay {
                Logger.debug("Minimizing window \(managed.windowId) from removed \(entry.context.descriptor.localizedName) [screen \(screenContextStore.loggingIndex(for: displayId))] due to display-removal policy")
                clearManagedWindowZone(managed)
                minimizeWindowProgrammatically(managed, reason: "display-removal")
            }
        }
    }

}
