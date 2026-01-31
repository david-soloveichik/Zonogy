import Foundation
import AppKit
import ApplicationServices

/// Startup capture routines, shortcut helpers, and bundle filtering utilities.
extension AppController {
    /// Restarts the app after accessibility permissions are granted.
    /// This ensures all CGEventTap-based interceptors (DockMenus, ZoneClickInterceptor,
    /// AltTabKeyInterceptor) initialize correctly with the new permissions.
    func restartAfterAccessibilityGranted() {
        Logger.debug("Accessibility permission granted - restarting app")

        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    internal func prepareExistingApplicationWindows() {
        var windowsByScreen: [CGDirectDisplayID: [ManagedWindow]] = [:]
        let visibleBundleIds = bundleIdsWithVisibleWindows()

        for application in NSWorkspace.shared.runningApplications {
            guard shouldManage(application: application, visibleBundleIds: visibleBundleIds) else {
                continue
            }

            let windows = captureWindows(for: application, notifyDelegate: false, allowExisting: false)
            for window in windows {
                // Skip minimized windows from zone placement - they're tracked for the launcher
                // but shouldn't be placed into zones during startup.
                // Use AX query since windows don't have zone assignments yet.
                guard !window.isMinimizedPerAccessibility else { continue }

                let resolvedScreenId = detectScreenId(for: window) ?? primaryScreenId
                guard screenContexts[resolvedScreenId] != nil else {
                    continue
                }
                windowsByScreen[resolvedScreenId, default: []].append(window)
            }
        }

        let orderedScreenIds = startupScreenProcessingOrder()
        for screenId in orderedScreenIds {
            guard let context = screenContexts[screenId] else {
                continue
            }

            let windows = windowsByScreen[screenId] ?? []
            let desiredZoneCount = max(1, min(windows.count, 3))
            let removedWindowIds = context.zoneController.setZoneCount(to: desiredZoneCount)

            // Clear placeholders when zone count changes
            if !removedWindowIds.isEmpty {
                placeholderCoordinator.clearPlaceholdersForScreen(screenId)
            }

            for removedId in removedWindowIds {
                if let removedWindow = windowController.window(withId: removedId) {
                    clearManagedWindowZone(removedWindow)
                    minimizeWindowProgrammatically(removedWindow, reason: "startup-trim-zone-count")
                }
            }

            var unassignedWindows = windows
            let zoneOrder = context.zoneController.allZones.sorted { $0.index < $1.index }
            let screenFrames = startupScreenFrames(for: windows, descriptor: context.descriptor)

            for zone in zoneOrder {
                guard !unassignedWindows.isEmpty else {
                    break
                }

                let selectedIndex = selectStartupWindowIndex(
                    for: zone,
                    from: unassignedWindows,
                    screenFrames: screenFrames,
                    descriptor: context.descriptor
                )

                let selectedWindow = unassignedWindows.remove(at: selectedIndex)
                windowPlacementManager.placeNewWindow(selectedWindow, preferredScreenId: screenId)
            }

            for window in unassignedWindows {
                clearManagedWindowZone(window)
                minimizeWindowProgrammatically(window, reason: "startup-unassigned-window")
            }
        }
    }

    /// Compute the left edge of a window in screen coordinates for ordering.
    private func screenMinX(for managed: ManagedWindow, descriptor: ScreenDescriptor) -> CGFloat {
        guard let cocoaFrame = cocoaFrame(for: managed) else {
            return .greatestFiniteMagnitude
        }
        return descriptor.cocoaToScreen(cocoaFrame).minX
    }

    /// Ensure we iterate screens deterministically, covering every known context.
    private func startupScreenProcessingOrder() -> [CGDirectDisplayID] {
        var ordered = screenOrder
        for screenId in screenContexts.keys where !ordered.contains(screenId) {
            ordered.append(screenId)
        }
        return ordered
    }

    /// Cache window frames expressed in screen coordinates for startup ordering.
    private func startupScreenFrames(for windows: [ManagedWindow], descriptor: ScreenDescriptor) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for window in windows {
            guard let cocoaFrame = cocoaFrame(for: window) else {
                continue
            }
            frames[window.windowId] = descriptor.cocoaToScreen(cocoaFrame)
        }
        return frames
    }

    /// Choose a window for the specified zone based on overlap-first ordering.
    private func selectStartupWindowIndex(
        for zone: Zone,
        from windows: [ManagedWindow],
        screenFrames: [Int: CGRect],
        descriptor: ScreenDescriptor
    ) -> Int {
        var bestIndex = 0
        var bestArea: CGFloat = -1
        var bestLeft: CGFloat = .greatestFiniteMagnitude
        var bestWindowId = Int.max

        for (index, window) in windows.enumerated() {
            let area = startupOverlapArea(for: window.windowId, zone: zone, screenFrames: screenFrames)
            if area > bestArea {
                bestArea = area
                bestIndex = index
                bestLeft = screenFrames[window.windowId]?.minX ?? screenMinX(for: window, descriptor: descriptor)
                bestWindowId = window.windowId
                continue
            }

            if area == bestArea && area > 0 {
                let candidateLeft = screenFrames[window.windowId]?.minX ?? screenMinX(for: window, descriptor: descriptor)
                if candidateLeft < bestLeft || (candidateLeft == bestLeft && window.windowId < bestWindowId) {
                    bestIndex = index
                    bestLeft = candidateLeft
                    bestWindowId = window.windowId
                }
            }
        }

        if bestArea > 0 {
            return bestIndex
        }

        return leftMostStartupWindowIndex(from: windows, descriptor: descriptor)
    }

    /// Compute overlap area between a window and zone in screen coordinates.
    private func startupOverlapArea(
        for windowId: Int,
        zone: Zone,
        screenFrames: [Int: CGRect]
    ) -> CGFloat {
        guard let frame = screenFrames[windowId] else {
            return 0
        }
        let intersection = frame.intersection(zone.frame)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }
        return intersection.width * intersection.height
    }

    /// Return the index of the left-most window among the provided list.
    private func leftMostStartupWindowIndex(from windows: [ManagedWindow], descriptor: ScreenDescriptor) -> Int {
        var bestIndex = 0
        var bestLeft = CGFloat.greatestFiniteMagnitude
        var bestWindowId = Int.max

        for (index, window) in windows.enumerated() {
            let leftX = screenMinX(for: window, descriptor: descriptor)
            if leftX < bestLeft || (leftX == bestLeft && window.windowId < bestWindowId) {
                bestIndex = index
                bestLeft = leftX
                bestWindowId = window.windowId
            }
        }

        return bestIndex
    }

    internal func handleApplicationEvent(_ application: NSRunningApplication?) {
        guard let application else {
            Logger.debug("handleApplicationEvent: application is nil, skipping")
            return
        }

        let appDescription = "\(application.localizedName ?? "Unknown") (pid \(application.processIdentifier), bundle \(application.bundleIdentifier ?? "nil"))"

        guard shouldManage(application: application, logRejection: true) else {
            return
        }

        Logger.debug("handleApplicationEvent: scheduling capture for \(appDescription)")
        scheduleCapture(for: application, delay: 0.0)
        scheduleCapture(for: application, delay: 0.4)
    }

    internal func handleApplicationStateChange(_ application: NSRunningApplication?) {
        guard let application else {
            return
        }

        guard shouldManage(application: application) else {
            return
        }

        // When an application changes state (deactivate/hide), validate all its windows
        // This catches window closures that didn't fire destroy notifications
        _ = validationRetryManager.validateWindowsForApplication(pid: application.processIdentifier, trigger: .workspaceStateChange)
    }

    internal func handleApplicationTermination(_ application: NSRunningApplication?) {
        guard let application else {
            Logger.debug("NSWorkspace notification received: didTerminateApplication (no application payload)")
            return
        }

        let name = application.localizedName ?? "Unknown App"
        var details = "\(name), pid \(application.processIdentifier)"
        if let bundleId = application.bundleIdentifier {
            details += ", bundle \(bundleId)"
        }
        Logger.debug("NSWorkspace notification received: didTerminateApplication (\(details))")

        // Notify full-screen tracker that this app terminated
        notifyFullScreenTrackerOfAppTermination(pid: application.processIdentifier)

        capturePipeline.cancelRetry(forPid: application.processIdentifier)

        // When an application terminates, remove all of its managed windows immediately
        let removedWindowIds = windowController.removeAllWindows(forPid: application.processIdentifier)
        if removedWindowIds.isEmpty {
            Logger.debug("Application terminated, but no managed windows were associated with pid \(application.processIdentifier)")
            return
        }

        Logger.debug("Application terminated, pruned \(removedWindowIds.count) windows")
        validationRetryManager.cancelValidationRetry(for: application.processIdentifier)
        handleDestroyedWindows(removedWindowIds, reason: "application-termination", retarget: true)
    }

    internal func scheduleCapture(for application: NSRunningApplication, delay: TimeInterval) {
        let pid = application.processIdentifier
        let originalBundleId = application.bundleIdentifier  // Capture bundle ID to verify identity
        let appName = application.localizedName ?? "Unknown"

        Logger.debug("scheduleCapture: scheduling capture for \(appName) (pid \(pid)) in \(delay)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard let refreshedApplication = NSRunningApplication(processIdentifier: pid) else {
                Logger.debug("scheduleCapture: pid \(pid) no longer running, aborting capture")
                return
            }

            // Verify the PID still belongs to the same application
            if let originalBundleId = originalBundleId,
               let refreshedBundleId = refreshedApplication.bundleIdentifier,
               originalBundleId != refreshedBundleId {
                Logger.debug("PID \(pid) has been reused by different app (was \(originalBundleId), now \(refreshedBundleId)), aborting capture")
                return
            }

            guard self.shouldManage(application: refreshedApplication, logRejection: true) else { return }

            _ = self.captureWindows(
                for: refreshedApplication,
                notifyDelegate: true,
                allowExisting: false
            )
        }
    }

    internal func shouldManage(application: NSRunningApplication, visibleBundleIds: Set<String>? = nil, logRejection: Bool = false) -> Bool {
        let appDescription = "\(application.localizedName ?? "Unknown") (pid \(application.processIdentifier), bundle \(application.bundleIdentifier ?? "nil"))"

        guard !application.isTerminated else {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - application is terminated") }
            return false
        }
        if application.processIdentifier == getpid() {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - same PID as Zonogy") }
            return false
        }

        // Determine the effective bundle ID - either from NSRunningApplication or derived from executable path
        var bundleId = application.bundleIdentifier
        if bundleId == nil,
           let executableURL = application.executableURL {
            let processName = executableURL.lastPathComponent
            if configuration.deriveBundleIdFromPathForProcesses.contains(processName),
               let derivedBundleId = Configuration.deriveBundleId(fromExecutableURL: executableURL) {
                bundleId = derivedBundleId
                Logger.debug("shouldManage: derived bundle ID '\(derivedBundleId)' from executable path for process '\(processName)'")
            }
        }

        guard let bundleId else {
            let processName = application.executableURL?.lastPathComponent ?? "unknown"
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - no bundle identifier (process '\(processName)' not in deriveBundleIdFromPathForProcesses or no bundle found in path)") }
            return false
        }

        if let visibleBundleIds = visibleBundleIds,
           !visibleBundleIds.contains(bundleId) {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - not in visible bundle IDs") }
            return false
        }
        if configuration.ignoredBundleIdentifiers.contains(bundleId) {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - in ignored bundle identifiers") }
            return false
        }
        if application.activationPolicy != .regular &&
            !windowController.applicationExceptionPolicy.ignoresActivationPolicy(forBundleIdentifier: bundleId) {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - activationPolicy is \(application.activationPolicy.rawValue), not .regular") }
            return false
        }
        if isXpcOrHelperProcess(application) {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - is XPC or helper process") }
            return false
        }
        return true
    }

    internal func bundleIdsWithVisibleWindows() -> Set<String> {
        // Use .excludeDesktopElements without .optionOnScreenOnly to include minimized windows
        // This allows us to track apps that only have minimized windows for the launcher
        guard let windowInfoList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var bundleIds: Set<String> = []
        for info in windowInfoList {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: ownerPid) else {
                continue
            }
            // Use native bundle ID if available, otherwise try to derive from executable path
            if let bundleId = app.bundleIdentifier {
                bundleIds.insert(bundleId)
            } else if let executableURL = app.executableURL {
                let processName = executableURL.lastPathComponent
                if configuration.deriveBundleIdFromPathForProcesses.contains(processName),
                   let derivedBundleId = Configuration.deriveBundleId(fromExecutableURL: executableURL) {
                    bundleIds.insert(derivedBundleId)
                }
            }
        }
        return bundleIds
    }

    private func isXpcOrHelperProcess(_ application: NSRunningApplication) -> Bool {
        guard let url = application.bundleURL else {
            return false
        }

        let path = url.path
        return path.hasSuffix(".xpc") ||
            path.contains("/Contents/XPCServices/") ||
            path.contains(".xpc/")
    }

    internal func triggerShortcut(_ action: HotkeyService.Action) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch action {
            case .addZone:
                self.addZone()
            case .removeZone:
                let screenId = self.activeScreenId()
                guard let removalIndex = self.zoneIndexForShortcutRemoval(on: screenId) else { return }
                if let context = self.screenContexts[screenId],
                   let zone = context.zoneController.zone(at: removalIndex) {
                    let targetedMatch = (self.targetedZoneKey?.screenId == screenId) && (self.targetedZoneKey?.index == removalIndex)
                    let screenIndex = self.screenContextStore.loggingIndex(for: screenId)
                    Logger.debug(
                        "Shortcut remove about to remove zone \(removalIndex) on \(context.descriptor.localizedName) " +
                        "[\(screenIndex)] (empty: \(zone.isEmpty), targeted: \(targetedMatch), window: \(zone.occupantWindowId.map(String.init) ?? "none"))"
                    )
                } else {
                    let screenIndex = self.screenContextStore.loggingIndex(for: screenId)
                    Logger.debug("Shortcut remove selected zone \(removalIndex) on screen \(screenIndex), but zone details unavailable")
                }
                _ = self.performRemoveZone(at: removalIndex, on: screenId, announce: true)
            case .captureTimeTravelLogs:
                self.captureTimeTravelLogs(triggerReason: "shortcut")
            case .flipKeyWindow:
                self.flipKeyWindowToAnotherScreen()
            case .clearOrResetZones:
                self.clearOrResetZones()
            case .clearOrResetZonesAtCursor:
                self.clearOrResetZonesAtCursor()
            case .targetTemporaryZone:
                self.targetTemporaryZone()
            case .targetTilingZone:
                self.targetTilingZone()
            case .navigateLeft:
                self.navigateLeft()
            case .navigateRight:
                self.navigateRight()
            case .minimizeActiveWindow:
                // If Launcher is open and targeting a tiled zone, remove that zone instead.
                // If only 1 zone on screen, just hide Launcher (don't enter UnderCovers).
                if self.launcherController.isActive,
                   let key = self.targetedZoneKey {
                    if let context = self.screenContexts[key.screenId],
                       context.zoneController.allZones.count > 1 {
                        Logger.debug("Cmd-M with Launcher open: removing targeted zone \(key.index) on screen \(self.screenContextStore.loggingIndex(for: key.screenId))")
                        _ = self.performRemoveZone(at: key.index, on: key.screenId, announce: false)
                    } else {
                        Logger.debug("Cmd-M with Launcher open: only 1 zone, hiding Launcher")
                        self.launcherController.hide()
                    }
                } else if !self.launcherController.isActive {
                    self.minimizeActiveWindow()
                }
            case .minimizeWindowOrRemoveZoneAtCursor:
                self.minimizeWindowOrRemoveZoneAtCursor()
            case .saveWinShotSnapshot:
                self.saveWinShotSnapshot()
            case .showWinShotChooser:
                self.showWinShotChooser()
            case .showLauncher:
                self.showLauncher()
            }
        }
    }

    internal func showLauncher() {
        // Shortcut only opens the Launcher; it doesn't close it if already open.
        // Use Escape to close the Launcher.
        showLauncherIfAllowed(trigger: "shortcut-show-launcher")
    }

    private func captureTimeTravelLogs(triggerReason: String) {
        let captureTime = Date()
        let cwd = FileManager.default.currentDirectoryPath
        let destinationURL = URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("time_travel_log.txt", isDirectory: false)
        let success = Logger.dumpRecentLogs(
            destinationURL: destinationURL,
            captureTimestamp: captureTime
        )
        if success {
            Logger.debug("Time-travel logs captured at \(destinationURL.path) (reason: \(triggerReason))")
        } else {
            Logger.debug("Time-travel log capture failed (reason: \(triggerReason))")
        }
    }

    private func zoneIndexForShortcutRemoval(on screenId: CGDirectDisplayID) -> Int? {
        guard let context = screenContexts[screenId] else {
            return nil
        }

        let zones = context.zoneController.allZones
        guard zones.count > 1 else {
            return nil
        }

        let activeIndices = activeZoneIndices(on: screenId)
        let activeList = activeIndices.sorted()
        Logger.debug(
            "Shortcut remove evaluating screen \(context.descriptor.localizedName) [screen \(screenContextStore.loggingIndex(for: screenId))] " +
            "with active zone indices: \(activeList)"
        )

        let targetedIndex: Int?
        if let targetedKey = targetedZoneKey, targetedKey.screenId == screenId {
            targetedIndex = targetedKey.index
        } else {
            targetedIndex = nil
        }

        let candidates = zones.filter { zone in
            return !activeIndices.contains(zone.index)
        }

        guard !candidates.isEmpty else {
            Logger.debug(
                "Shortcut remove found no removable zones on \(context.descriptor.localizedName) " +
                "[screen \(screenContextStore.loggingIndex(for: screenId))] (active zones: \(activeList), total zones: \(zones.count))"
            )
            return nil
        }

        let orderedCandidates = candidates.sorted { lhs, rhs in
            removalPriorityKey(for: lhs, targetedIndex: targetedIndex) <
                removalPriorityKey(for: rhs, targetedIndex: targetedIndex)
        }

        let description = orderedCandidates.map { zone -> String in
            let priority = removalPriorityKey(for: zone, targetedIndex: targetedIndex)
            let targetedFlag = (targetedIndex == zone.index)
            return "zone \(zone.index){empty:\(zone.isEmpty), targeted:\(targetedFlag), window:\(zone.occupantWindowId.map(String.init) ?? "none"), priority:\(priority)}"
        }.joined(separator: ", ")

        if let selected = orderedCandidates.first {
            Logger.debug(
                "Shortcut remove selected zone \(selected.index) on \(context.descriptor.localizedName) " +
                "[screen \(screenContextStore.loggingIndex(for: screenId))] from candidates [\(description)]"
            )
            return selected.index
        } else {
            Logger.debug(
                "Shortcut remove unable to choose among candidates on \(context.descriptor.localizedName) " +
                "[screen \(screenContextStore.loggingIndex(for: screenId))], descriptions: [\(description)]"
            )
            return nil
        }
    }

    private func removalPriorityKey(for zone: Zone, targetedIndex: Int?) -> (Int, Int, Int) {
        let emptinessRank = zone.isEmpty ? 0 : 1
        let targetedRank = (targetedIndex == zone.index) ? 1 : 0
        let indexRank = -zone.index
        return (emptinessRank, targetedRank, indexRank)
    }

    private func activeZoneIndices(on screenId: CGDirectDisplayID) -> Set<Int> {
        let screenName = screenContexts[screenId]?.descriptor.localizedName ?? "Unknown Screen"

        if let (managed, pid) = managedWindowForFrontmostApplication(logPrefix: "activeZoneIndices frontmost"),
           let zoneIndex = managed.zoneIndex,
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            Logger.debug(
                "activeZoneIndices: using frontmost pid \(pid) -> zone \(zoneIndex) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))]"
            )
            return [zoneIndex]
        }

        if let lastPid = lastActiveApplicationPid,
           let managed = windowController.focusedWindowIfTracked(pid: lastPid),
           let zoneIndex = managed.zoneIndex,
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            Logger.debug(
                "activeZoneIndices: using last active pid \(lastPid) -> zone \(zoneIndex) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))]"
            )
            return [zoneIndex]
        }

        guard let context = screenContexts[screenId] else {
            return []
        }

        var candidatePids: Set<pid_t> = []
        if let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPid != getpid() {
            candidatePids.insert(frontmostPid)
        }
        if let lastPid = lastActiveApplicationPid,
           lastPid != getpid() {
            candidatePids.insert(lastPid)
        }

        var indices: Set<Int> = []
        for zone in context.zoneController.allZones {
            guard let windowId = zone.occupantWindowId,
                  let managedWindow = windowController.window(withId: windowId),
                  (managedWindow.screenDisplayId ?? detectScreenId(for: managedWindow)) == screenId else {
                if let windowId = zone.occupantWindowId,
                   let managedWindow = windowController.window(withId: windowId) {
                    let hasScreen = (managedWindow.screenDisplayId ?? detectScreenId(for: managedWindow)) != nil
                    Logger.debug(
                        "activeZoneIndices: skipping zone \(zone.index) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))] " +
                        "for window \(windowId) (hasScreen: \(hasScreen))"
                    )
                } else if zone.occupantWindowId != nil {
                    Logger.debug(
                        "activeZoneIndices: no managed window for id \(zone.occupantWindowId!) in zone \(zone.index) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))]"
                    )
                }
                continue
            }

            let pid = managedWindow.backing.pid
            if candidatePids.contains(pid) {
                indices.insert(zone.index)
            } else {
                Logger.debug(
                    "activeZoneIndices: window \(windowId) pid \(pid) not in candidate pid set \(candidatePids) " +
                    "for zone \(zone.index) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))]"
                )
            }
        }
        Logger.debug(
            "activeZoneIndices: resolved indices \(indices.sorted()) for \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))] with candidate pids \(candidatePids)"
        )
        return indices
    }

}
