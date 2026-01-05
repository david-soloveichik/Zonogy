import Foundation
import AppKit
import ApplicationServices

/// Handles hotkeys, system events, and display reconfiguration.
extension AppController {
    internal func currentWindowCounts() -> (managed: Int, placeholders: Int) {
        var managed = 0
        var placeholders = 0
        for window in windowController.allWindows {
            if window.isPlaceholder {
                placeholders += 1
            } else {
                managed += 1
            }
        }
        return (managed, placeholders)
    }

    func hotkeyService(_ service: HotkeyService, didTrigger action: HotkeyService.Action) {
        switch action {
        case .addZone:
            Logger.debug("Hotkey add zone triggered")
        case .removeZone:
            Logger.debug("Hotkey remove zone triggered")
        case .captureTimeTravelLogs:
            Logger.debug("Hotkey capture time-travel logs triggered")
        case .flipKeyWindow:
            Logger.debug("Hotkey flip key window triggered")
        case .clearOrResetZones:
            Logger.debug("Hotkey clear or reset zones triggered")
        case .clearOrResetZonesAtCursor:
            Logger.debug("Hotkey clear or reset zones at cursor triggered")
        case .targetTemporaryZone:
            Logger.debug("Hotkey target temporary zone triggered")
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
            _ = validationRetryManager.validateWindowsForApplication(pid: previousPid, reason: "workspace-activation-previous-app")
            handleManualResizeFocusChange(pid: previousPid, focusedWindowId: nil)
        }
        if let application {
            lastActiveApplicationPid = application.processIdentifier
        }
        handleApplicationEvent(application)
        handleActiveFitActivationCandidate(pid: application?.processIdentifier)
        handleTemporaryZoneActivationChange(focusedPid: application?.processIdentifier, reason: "workspace-activate")
        updateUnmanagedFocusState()

        // Record window activity for AltTab recency tracking.
        // AXFocusedWindowChanged notifications only fire when focus changes within an app,
        // not when the app itself is activated. So we proactively record activity here to
        // ensure the focused window appears correctly in the AltTab recency list.
        if let pid = application?.processIdentifier,
           let focused = windowController.focusedWindowIfTracked(pid: pid) {
            windowController.recordWindowActivity(windowId: focused.windowId)
        }
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didLaunch application: NSRunningApplication?) {
        let appDescription = application.map { "\($0.localizedName ?? "Unknown"), pid \($0.processIdentifier), bundle \($0.bundleIdentifier ?? "nil")" } ?? "nil"
        Logger.debug("NSWorkspace notification received: didLaunchApplication (\(appDescription))")
        if shouldIgnoreDueToSleepWake(event: "NSWorkspace.didLaunchApplicationNotification") {
            return
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
            guard case .accessibility(_, let windowPid, _) = window.backing,
                  windowPid == pid,
                  !window.isPlaceholder else {
                continue
            }

            hasManagedWindows = true
            if !window.isMinimized {
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
                let wasManualResizeDetached = performProgrammaticMinimizeCleanup(
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
                    wasManualResizeDetached: wasManualResizeDetached
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
    /// If the focused window is unmanaged, stores its screen ID; otherwise clears the state.
    /// Calls `refreshResizeHandles()` when the state changes.
    internal func updateUnmanagedFocusState() {
        let previousScreenId = unmanagedFocusedWindowScreenId
        let newScreenId = screenIdForUnmanagedFocusedWindow()
        unmanagedFocusedWindowScreenId = newScreenId

        if previousScreenId != newScreenId {
            refreshResizeHandles()
        }
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

        if rebuildResult.addedDisplayIds.isEmpty,
           rebuildResult.removedContexts.isEmpty,
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

        if !rebuildResult.removedContexts.isEmpty {
            handleRemovedScreens(rebuildResult.removedContexts)
        }

        // Validate all external windows to drop stale references
        var pidsToValidate = Set<pid_t>()
        for window in windowController.allWindows {
            if case .accessibility(_, let pid, _) = window.backing {
                pidsToValidate.insert(pid)
            }
        }

        for pid in pidsToValidate {
            _ = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "screen-change")
        }

        targetedZoneManager.ensureTargetedZone(reason: "screens-changed")

        syncWindowsToZones()

        // Recapture after displays settle when meaningful changes occurred.
        // Always recapture after wake to catch windows that were deminiaturized or
        // created while events were suppressed during the sleep transition.
        if includesWake || !rebuildResult.addedDisplayIds.isEmpty || !rebuildResult.removedContexts.isEmpty || rebuildResult.orderChanged {
            let recaptureReason = includesWake ? "wake" : "screen-change"
            scheduleWindowRecapture(delay: 0.5, reason: recaptureReason)
            scheduleWindowRecapture(delay: 1.5, reason: recaptureReason)
        }
    }

    private func handleRemovedScreens(_ removed: [ScreenContextStore.RebuildResult.RemovedContext]) {
        for entry in removed {
            let displayId = entry.displayId

            // Snapshot all non-placeholder windows that currently report this
            // displayId *before* we close placeholders. Closing a placeholder triggers
            // windowWillClose → syncWindowsToZones, and that sync can clear screenDisplayId
            // for windows on the removed display. If we computed windowsOnDisplay after
            // those syncs, we would miss windows that should be
            // minimized as part of the display-removal policy.
            let windowsOnDisplay = windowController.allWindows.filter {
                !$0.isPlaceholder && $0.screenDisplayId == displayId
            }

            // Clear any placeholder bookkeeping tied to this display.
            placeholderCoordinator.clearMappingsForScreen(displayId)

            // Close all placeholder windows that were on the removed display.
            let placeholders = windowController.allWindows.filter { $0.isPlaceholder && $0.screenDisplayId == displayId }
            for placeholder in placeholders {
                Logger.debug("Closing placeholder \(placeholder.windowId) for removed screen \(displayId)")
                windowController.closeWindow(placeholder)
                placeholderCoordinator.forget(windowId: placeholder.windowId)
            }

            let zoneCount = entry.context.zoneController.allZones.count
            Logger.debug("Handling removal of screen \(entry.context.descriptor.localizedName) [\(displayId)] with \(zoneCount) zone(s)")

            // Minimize every non-placeholder managed window that was on the removed display,
            // instead of reassigning it to another screen. We rely on the pre-snapshot
            // windowsOnDisplay so this is robust even if earlier syncs cleared
            // screenDisplayId for those windows.
            for managed in windowsOnDisplay {
                Logger.debug("Minimizing window \(managed.windowId) from removed screen \(displayId) due to display-removal policy")
                clearManagedWindowZone(managed)
                minimizeWindowProgrammatically(managed, reason: "display-removal")
            }
        }
    }

}
