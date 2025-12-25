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
        case .navigateUp:
            Logger.debug("Hotkey navigate up triggered")
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
        dismissLauncherIfActive()
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

    internal func scheduleScreenTopologyRefresh(reason: String, affectedDisplayIds: Set<CGDirectDisplayID> = []) {
        suppressManualMoveHandling(for: manualMoveSuppressionDuration, reason: reason)
        if let existingReason = pendingScreenChangeReason {
            pendingScreenChangeReason = "\(existingReason),\(reason)"
        } else {
            pendingScreenChangeReason = reason
        }

        pendingScreenChangeDisplayIds.formUnion(affectedDisplayIds)

        pendingScreenChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let hintedIds = self.pendingScreenChangeDisplayIds
            let resolvedReason = self.pendingScreenChangeReason ?? reason
            self.pendingScreenChangeDisplayIds.removeAll()
            self.pendingScreenChangeReason = nil
            self.performScreenTopologyRefresh(reason: resolvedReason, hintedDisplayIds: hintedIds)
        }
        pendingScreenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + screenChangeDebounceInterval, execute: workItem)
    }

    private func performScreenTopologyRefresh(reason: String, hintedDisplayIds: Set<CGDirectDisplayID>) {
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

        // Recapture after displays settle when meaningful changes occurred
        if !rebuildResult.addedDisplayIds.isEmpty || !rebuildResult.removedContexts.isEmpty || rebuildResult.orderChanged {
            scheduleWindowRecapture(delay: 0.5, reason: "screen-change")
            scheduleWindowRecapture(delay: 1.5, reason: "screen-change")
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
