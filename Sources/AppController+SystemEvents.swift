import Foundation
import AppKit
import ApplicationServices

/// Handles hotkeys, system events, display reconfiguration, and recapture scheduling.
extension AppController {
    func hotkeyService(_ service: HotkeyService, didTrigger action: HotkeyService.Action) {
        switch action {
        case .addZone:
            Logger.debug("Hotkey add zone triggered")
        case .removeZone:
            Logger.debug("Hotkey remove zone triggered")
        case .captureTimeTravelLogs:
            Logger.debug("Hotkey capture time-travel logs triggered")
        }
        triggerShortcut(action)
    }

    // MARK: - SystemEventMonitorDelegate

    func systemEventMonitor(_ monitor: SystemEventMonitor, handleKeyEvent event: NSEvent) -> Bool {
        hotkeyService.handleLocalShortcut(event: event)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didActivate application: NSRunningApplication?) {
        if let previousPid = lastActiveApplicationPid {
            _ = validationRetryManager.validateWindowsForApplication(pid: previousPid, reason: "workspace-activation-previous-app")
        }
        if let application {
            lastActiveApplicationPid = application.processIdentifier
        }
        handleApplicationEvent(application)
        handleKeyFitActivationCandidate(pid: application?.processIdentifier)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didLaunch application: NSRunningApplication?) {
        handleApplicationEvent(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didUnhide application: NSRunningApplication?) {
        handleApplicationEvent(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didDeactivate application: NSRunningApplication?) {
        handleApplicationStateChange(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didHide application: NSRunningApplication?) {
        handleApplicationStateChange(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didTerminate application: NSRunningApplication?) {
        handleApplicationTermination(application)
    }

    func systemEventMonitorWillSleep(_ monitor: SystemEventMonitor) {
        // Log current state before sleep
        var managedWindowCount = 0
        var placeholderCount = 0
        for window in windowController.allWindows {
            if window.isPlaceholder {
                placeholderCount += 1
            } else {
                managedWindowCount += 1
            }
        }
        Logger.debug("System will sleep - current state: \(managedWindowCount) managed windows, \(placeholderCount) placeholders")
    }

    func systemEventMonitorDidWake(_ monitor: SystemEventMonitor) {
        // Log initial state after wake
        var initialManagedCount = 0
        var initialPlaceholderCount = 0
        for window in windowController.allWindows {
            if window.isPlaceholder {
                initialPlaceholderCount += 1
            } else {
                initialManagedCount += 1
            }
        }
        Logger.debug("System did wake - initial state: \(initialManagedCount) managed windows, \(initialPlaceholderCount) placeholders - scheduling delayed window recapture")

        // First, validate and prune any destroyed windows from existing managed windows
        var pidsToValidate = Set<pid_t>()
        for window in windowController.allWindows {
            if case .accessibility(_, let pid, _) = window.backing {
                pidsToValidate.insert(pid)
            }
        }

        Logger.debug("Validating \(pidsToValidate.count) PIDs from existing managed windows")
        for pid in pidsToValidate {
            let pruned = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "system-wake-validation")
            if !pruned.isEmpty {
                Logger.debug("Pruned \(pruned.count) destroyed windows for pid \(pid)")
            }
        }

        // Force immediate sync to ensure placeholders are shown
        syncWindowsToZones()

        // Schedule window recapture after a delay to allow the Accessibility API to stabilize
        // We use multiple attempts with increasing delays to handle different wake scenarios
        scheduleWindowRecapture(delay: 0.5, reason: "wake")
        scheduleWindowRecapture(delay: 1.5, reason: "wake")
        scheduleWindowRecapture(delay: 3.0, reason: "wake")
    }

    private func scheduleWindowRecapture(delay: TimeInterval, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            Logger.debug("Attempting \(reason) recapture after \(delay) seconds")

            // Count how many windows we currently have
            var preCaptureManaged = 0
            var prePlaceholders = 0
            for window in self.windowController.allWindows {
                if window.isPlaceholder {
                    prePlaceholders += 1
                } else {
                    preCaptureManaged += 1
                }
            }

            // Recapture windows from all running applications
            let visibleBundleIds = self.bundleIdsWithVisibleWindows()
            var capturedCount = 0
            for application in NSWorkspace.shared.runningApplications {
                guard self.shouldManage(application: application, visibleBundleIds: visibleBundleIds) else {
                    continue
                }

                // Capture windows, allowing existing ones to be returned
                let capturedWindows = self.captureWindows(
                    for: application,
                    notifyDelegate: true,
                    allowExisting: true
                )
                if !capturedWindows.isEmpty {
                    capturedCount += capturedWindows.count
                    Logger.debug("Captured \(capturedWindows.count) windows for \(application.bundleIdentifier ?? "unknown") (pid \(application.processIdentifier))")
                }
            }

            // Only sync if we captured new windows
            if capturedCount > 0 {
                self.syncWindowsToZones()

                // Log the result
                var postCaptureManaged = 0
                var postPlaceholders = 0
                for window in self.windowController.allWindows {
                    if window.isPlaceholder {
                        postPlaceholders += 1
                    } else {
                        postCaptureManaged += 1
                    }
                }

                Logger.debug("\(reason.capitalized) recapture after \(delay)s: captured \(capturedCount) windows, managed: \(preCaptureManaged) -> \(postCaptureManaged), placeholders: \(prePlaceholders) -> \(postPlaceholders)")
            }
        }
    }

    func systemEventMonitorScreensDidChange(_ monitor: SystemEventMonitor) {
        Logger.debug("Screen configuration change notification received from AppKit")
        scheduleScreenTopologyRefresh(reason: "appkit-notification")
    }

    // MARK: - DisplayReconfigurationMonitorDelegate

    func displayMonitor(_ monitor: DisplayReconfigurationMonitor, didObserve event: DisplayReconfigurationMonitor.Event) {
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

    private func scheduleScreenTopologyRefresh(reason: String, affectedDisplayIds: Set<CGDirectDisplayID> = []) {
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
            placeholderCoordinator.clearMappingsForScreen(entry.displayId)
            let placeholders = windowController.allWindows.filter { $0.isPlaceholder && $0.screenDisplayId == entry.displayId }
            for placeholder in placeholders {
                Logger.debug("Closing placeholder \(placeholder.windowId) for removed screen \(entry.displayId)")
                windowController.closeWindow(placeholder)
                placeholderCoordinator.forget(windowId: placeholder.windowId)
            }
            let zoneCount = entry.context.zoneController.allZones.count
            Logger.debug("Handling removal of screen \(entry.context.descriptor.localizedName) [\(entry.displayId)] with \(zoneCount) zone(s)")

            for zone in entry.context.zoneController.allZones {
                guard let windowId = zone.windowId,
                      let managed = windowController.window(withId: windowId) else {
                    continue
                }

                if managed.isPlaceholder {
                    Logger.debug("Closing placeholder \(managed.windowId) tied to removed screen \(entry.displayId)")
                    windowController.closeWindow(managed)
                    placeholderCoordinator.forget(windowId: managed.windowId)
                    continue
                }

                Logger.debug("Reassigning window \(managed.windowId) from removed screen \(entry.displayId)")
                clearManagedWindowZone(managed)
                windowPlacementManager.placeNewWindow(managed, preferredScreenId: activeScreenId())
            }
        }
    }

}
