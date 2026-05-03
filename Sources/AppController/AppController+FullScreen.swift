/// Full-screen mode tracking integration.
import AppKit
import ApplicationServices

struct FullScreenElementInfo: Equatable {
    let pid: pid_t
    let cgWindowId: CGWindowID
}

extension AppController {
    // MARK: - FullScreenTrackerDelegate
    func fullScreenTracker(_ tracker: FullScreenTracker, didChangeFullScreenStateFor displayId: CGDirectDisplayID) {
        updateFullScreenDebugOverlay(for: displayId)
        handleFullScreenPauseStateChange(for: displayId)
    }

    internal var isFullScreenDebugOverlayEnabledInSettings: Bool {
        DebugPreferencesStore.loadFullScreenOverlayEnabled()
    }

    internal func setFullScreenDebugOverlayEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("FullScreenDebugOverlay: settings updated enabled=\(enabled)")
        DebugPreferencesStore.saveFullScreenOverlayEnabled(enabled)
        applyFullScreenDebugOverlayConfiguration(enabled: enabled)
    }

    /// Update the debug overlay for a specific display based on full-screen state.
    internal func updateFullScreenDebugOverlay(for displayId: CGDirectDisplayID) {
        guard let overlay = fullScreenDebugOverlay else { return }

        if fullScreenTracker.isFullScreen(displayId: displayId) {
            // Show orange frame around the screen
            guard let context = screenContexts[displayId] else {
                overlay.hideOverlay(for: displayId)
                return
            }

            // Convert screen bounds to accessibility coordinates for the overlay
            let cocoaBounds = context.descriptor.cocoaBounds
            let accessibilityBounds = CoordinateConversion.cocoaToAccessibility(
                cocoaFrame: cocoaBounds,
                primaryScreenBounds: primaryScreenBounds
            )
            overlay.setScreenFrame(displayId: displayId, screenFrame: accessibilityBounds)
        } else {
            overlay.hideOverlay(for: displayId)
        }
    }

    /// Update debug overlays for all screens.
    internal func updateAllFullScreenDebugOverlays() {
        guard fullScreenDebugOverlay != nil else { return }
        for displayId in screenContexts.keys {
            updateFullScreenDebugOverlay(for: displayId)
        }
    }

    private func applyFullScreenDebugOverlayConfiguration(enabled: Bool) {
        if enabled {
            if fullScreenDebugOverlay == nil {
                fullScreenDebugOverlay = FullScreenDebugOverlayController(primaryScreenBounds: primaryScreenBounds)
            }
            updateAllFullScreenDebugOverlays()
            return
        }

        fullScreenDebugOverlay?.hideAll()
        fullScreenDebugOverlay = nil
    }

    internal func isScreenPausedForFullScreen(_ screenId: CGDirectDisplayID) -> Bool {
        fullScreenTracker.isFullScreen(displayId: screenId)
    }

    /// Returns `true` when `screenId` is paused for a native macOS full-screen window — the
    /// green-button variety that lives in its own dedicated Space.
    ///
    /// The tracker's `isNativeFullScreen` flag (set from AX `AXFullScreen`) is the primary
    /// signal; the CGS Space membership re-check is defensive duplication of the tracker's
    /// invariants (the tracker's on-screen filter already keeps that flag honest). It can be
    /// dropped without changing behavior — see SPECIFICATION-IMPLEMENTATION.md for the
    /// load-bearing vs defensive split.
    internal func isNativeFullScreenPause(screenId: CGDirectDisplayID) -> Bool {
        guard let info = fullScreenTracker.fullScreenWindowInfo(for: screenId),
              info.isNativeFullScreen else {
            return false
        }
        return SpaceQueries.isWindowInNativeFullScreenSpace(cgWindowId: info.cgWindowId)
    }

    /// Partial-pause follow-up: re-raises `originScreenId`'s full-screen window so macOS
    /// switches that display back to its full-screen Space. Invoked only after a
    /// `placeNewWindow` whose decision was `.placeAndRestoreNativeFullScreenSpace`. The
    /// `isNativeFullScreen` + CGS Space re-check is defensive — it guards against a race
    /// where the screen exited full-screen between the decision and this call.
    internal func restoreNativeFullScreenSpaceAfterPartialPause(originScreenId: CGDirectDisplayID) {
        guard let info = fullScreenTracker.fullScreenWindowInfo(for: originScreenId),
              info.isNativeFullScreen,
              SpaceQueries.isWindowInNativeFullScreenSpace(cgWindowId: info.cgWindowId) else {
            let screenIndex = screenContextStore.loggingIndex(for: originScreenId)
            Logger.debug(
                "Partial-pause restore: skipped on screen \(screenIndex) " +
                    "(no longer in native full-screen mode)"
            )
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: originScreenId)
        let bundleDesc = info.bundleIdentifier ?? "unknown"
        Logger.debug(
            "Partial-pause restore: re-raising full-screen window (CGWindowID \(info.cgWindowId), bundle: \(bundleDesc)) " +
                "to switch screen \(screenIndex) back to its full-screen Space"
        )
        scheduleWindowRaise(
            pid: info.pid,
            element: info.element,
            logPrefix: "Partial-pause restore",
            reason: "native-full-screen-space-restore"
        )
    }

    /// Clears the full-screen pause on `screenId` when:
    /// - the focused window on that display does not itself claim full-screen, AND
    /// - the recorded FS window's status cannot be confirmed by CGS Spaces as a native FS Space.
    ///
    /// CGS Space membership is the stop sign for native FS: while a recorded native FS window
    /// still belongs to a `kCGSSpaceFullscreen` Space, the pause is real — its FS Space is
    /// just inactive because another Space is showing. The pause is only cleared when there
    /// is no surviving FS Space membership to anchor it.
    internal func repairFullScreenPauseStateFromFocusedWindowIfNeeded(
        focusedWindow: AXUIElement,
        pid: pid_t,
        screenId: CGDirectDisplayID,
        reason: String
    ) {
        guard isScreenPausedForFullScreen(screenId) else {
            return
        }

        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let treatAsFullScreen = shouldTreatAXUnknownWindowAsFullScreen(
            element: focusedWindow,
            bundleIdentifier: bundleId,
            screenDisplayId: screenId
        )
        let focusedClaimsFullScreen = FullScreenTracker.isWindowFullScreen(element: focusedWindow) || treatAsFullScreen
        guard !focusedClaimsFullScreen else {
            return
        }

        if let info = fullScreenTracker.fullScreenWindowInfo(for: screenId),
           info.isNativeFullScreen,
           SpaceQueries.isWindowInNativeFullScreenSpace(cgWindowId: info.cgWindowId) {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug(
                "FullScreenTracker: keeping native full-screen pause on screen \(screenIndex) " +
                    "(focused window not FS but recorded FS window still in native FS Space) (reason: \(reason))"
            )
            return
        }

        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug(
            "FullScreenTracker: clearing stale full-screen pause on screen \(screenIndex) " +
                "because focused window is not full-screen (reason: \(reason))"
        )
        fullScreenTracker.clearFullScreenState(displayId: screenId, reason: "focused-window-not-full-screen-\(reason)")
    }

    /// Notify full-screen tracker that an application terminated.
    internal func notifyFullScreenTrackerOfAppTermination(pid: pid_t) {
        clearFullScreenElementCache(for: pid)
        fullScreenTracker.applicationDidTerminate(pid: pid)
    }

    /// Notify full-screen tracker that a specific window closed.
    internal func notifyFullScreenTrackerOfWindowClose(windowId: Int) {
        fullScreenTracker.windowDidClose(windowId: windowId)
    }

    /// Notify full-screen tracker that a specific window closed (managed or unmanaged).
    internal func notifyFullScreenTrackerOfWindowClose(cgWindowId: CGWindowID, pid: pid_t) {
        fullScreenTracker.windowDidClose(cgWindowId: cgWindowId, pid: pid)
    }

    /// Check full-screen state for a window after resize.
    /// Called when kAXResizedNotification is received for a managed window.
    internal func checkWindowFullScreenState(windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            return
        }

        let screenDisplayId = detectScreenId(for: managed.backing.element) ?? managed.screenDisplayId
        checkWindowFullScreenState(
            element: managed.backing.element,
            pid: managed.backing.pid,
            windowId: windowId,
            cgWindowId: CGWindowID(managed.backing.cgWindowId),
            bundleIdentifier: NSRunningApplication(processIdentifier: managed.backing.pid)?.bundleIdentifier,
            screenDisplayIdHint: screenDisplayId
        )
    }

    /// Debounce full-screen state checks for a managed window during resize bursts.
    internal func queueFullScreenCheck(windowId: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fullScreenCheckWorkItemsByWindowId.removeValue(forKey: windowId)
            self.checkWindowFullScreenState(windowId: windowId)
        }
        fullScreenCheckWorkItemsByWindowId[windowId]?.cancel()
        fullScreenCheckWorkItemsByWindowId[windowId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fullScreenCheckDebounceInterval, execute: workItem)
    }

    /// Debounce full-screen state checks for an unmanaged window during resize bursts.
    internal func queueFullScreenCheck(element: AXUIElement, pid: pid_t) {
        let elementKey = AccessibilityElementKey(element: element)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fullScreenCheckWorkItemsByElement.removeValue(forKey: elementKey)
            self.checkWindowFullScreenState(element: element, pid: pid)
        }
        fullScreenCheckWorkItemsByElement[elementKey]?.cancel()
        fullScreenCheckWorkItemsByElement[elementKey] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fullScreenCheckDebounceInterval, execute: workItem)
    }

    /// Debounce a full-screen rescan after the active space changes.
    internal func scheduleFullScreenRescanForSpaceChange() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFullScreenSpaceChangeWorkItem = nil
            Logger.debug("FullScreenTracker: refreshing full-screen state after active space change")
            self.scanAllWindowsForFullScreenState()
            self.updateUnmanagedFocusState()
        }

        pendingFullScreenSpaceChangeWorkItem?.cancel()
        pendingFullScreenSpaceChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fullScreenSpaceChangeDebounceInterval, execute: workItem)
    }

    /// Check full-screen state for an arbitrary window element.
    internal func checkWindowFullScreenState(element: AXUIElement, pid: pid_t) {
        checkWindowFullScreenState(
            element: element,
            pid: pid,
            windowId: nil,
            cgWindowId: resolveCgWindowId(for: element),
            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            screenDisplayIdHint: nil
        )
    }

    /// Scan all eligible windows for their full-screen state.
    /// Called at startup and after display reconfiguration to detect windows
    /// that are already in full-screen mode.
    internal func scanAllWindowsForFullScreenState() {
        guard windowController.ensureAccessibilityPermissions() else {
            return
        }

        // Batch updates so a rescan (especially after a space change) cannot transiently
        // unpause then re-pause a screen while we are still enumerating windows.
        let previousFullScreenDisplayIds = fullScreenTracker.fullScreenDisplayIds
        let savedDelegate = fullScreenTracker.delegate
        fullScreenTracker.delegate = nil
        defer { fullScreenTracker.delegate = savedDelegate }

        var observedWindowIds: Set<CGWindowID> = []

        for managed in windowController.allWindows {
            let cgWindowId = CGWindowID(managed.backing.cgWindowId)
            observedWindowIds.insert(cgWindowId)
            checkWindowFullScreenState(windowId: managed.windowId)
        }

        for application in NSWorkspace.shared.runningApplications {
            guard shouldManage(application: application) else {
                continue
            }

            let pid = application.processIdentifier
            let appElement = windowController.accessibilityWatcher.applicationElement(for: pid)
            _ = windowController.accessibilityWatcher.ensureObserver(
                for: pid,
                appElement: appElement,
                bundleIdentifier: application.bundleIdentifier
            )

            let windowElements = windowElements(for: appElement)
            for element in windowElements {
                guard let cgWindowId = resolveCgWindowId(for: element) else {
                    continue
                }
                if observedWindowIds.contains(cgWindowId) {
                    continue
                }
                windowController.accessibilityWatcher.registerWindowNotifications(for: element, pid: pid)
                checkWindowFullScreenState(
                    element: element,
                    pid: pid,
                    windowId: nil,
                    cgWindowId: cgWindowId,
                    bundleIdentifier: application.bundleIdentifier,
                    screenDisplayIdHint: nil
                )
            }
        }
        updateAllFullScreenDebugOverlays()

        let newFullScreenDisplayIds = fullScreenTracker.fullScreenDisplayIds
        let changedDisplayIds = previousFullScreenDisplayIds.symmetricDifference(newFullScreenDisplayIds)
        for displayId in changedDisplayIds {
            updateFullScreenDebugOverlay(for: displayId)
            handleFullScreenPauseStateChange(for: displayId)
        }
    }

    private func checkWindowFullScreenState(
        element: AXUIElement,
        pid: pid_t,
        windowId: Int?,
        cgWindowId: CGWindowID?,
        bundleIdentifier: String?,
        screenDisplayIdHint: CGDirectDisplayID?
    ) {
        guard let application = NSRunningApplication(processIdentifier: pid),
              shouldManage(application: application) else {
            return
        }

        guard let resolvedCgWindowId = cgWindowId else {
            return
        }

        // Display resolution: prefer the caller hint, then live AX detection. If neither is
        // available, anchor a tracked native FS window to its existing recorded display
        // (its FS Space is just inactive). Otherwise fall back to the primary display. The
        // CGS Space membership check here is defensive — the tracker entry alone is enough,
        // but the extra confirmation costs little and fails closed.
        let resolvedDisplayId: CGDirectDisplayID = {
            if let screenDisplayIdHint { return screenDisplayIdHint }
            if let detected = detectScreenId(for: element) { return detected }
            if let cachedDisplayId = fullScreenTracker.displayId(forCgWindowId: resolvedCgWindowId, pid: pid),
               let info = fullScreenTracker.fullScreenWindowInfo(for: cachedDisplayId),
               info.isNativeFullScreen,
               SpaceQueries.isWindowInNativeFullScreenSpace(cgWindowId: resolvedCgWindowId) {
                return cachedDisplayId
            }
            return primaryScreenId
        }()
        let resolvedBundleId = bundleIdentifier ?? application.bundleIdentifier

        let elementKey = AccessibilityElementKey(element: element)
        fullScreenElementCache[elementKey] = FullScreenElementInfo(pid: pid, cgWindowId: resolvedCgWindowId)

        let treatAsFullScreen = shouldTreatAXUnknownWindowAsFullScreen(
            element: element,
            bundleIdentifier: resolvedBundleId,
            screenDisplayId: resolvedDisplayId
        )

        fullScreenTracker.handleWindowFullScreenStateChange(
            windowId: windowId,
            cgWindowId: resolvedCgWindowId,
            element: element,
            pid: pid,
            bundleIdentifier: resolvedBundleId,
            screenDisplayId: resolvedDisplayId,
            treatAsFullScreen: treatAsFullScreen
        )
    }

    internal func resolveCgWindowId(for element: AXUIElement) -> CGWindowID? {
        var cgWindowId: CGWindowID = 0
        let status = AXCall.getWindow(element, &cgWindowId)
        guard status == .success, cgWindowId != 0 else {
            return nil
        }
        return cgWindowId
    }

    private func clearFullScreenElementCache(for pid: pid_t) {
        let keysToRemove = fullScreenElementCache.compactMap { entry in
            entry.value.pid == pid ? entry.key : nil
        }
        for key in keysToRemove {
            fullScreenElementCache.removeValue(forKey: key)
            if let workItem = fullScreenCheckWorkItemsByElement.removeValue(forKey: key) {
                workItem.cancel()
            }
        }
    }

    private func shouldTreatAXUnknownWindowAsFullScreen(
        element: AXUIElement,
        bundleIdentifier: String?,
        screenDisplayId: CGDirectDisplayID
    ) -> Bool {
        guard let bundleIdentifier,
              windowController.applicationExceptionPolicy.treatsAXUnknownFullWidthAsFullScreen(forBundleIdentifier: bundleIdentifier) else {
            return false
        }

        var subroleValue: CFTypeRef?
        let subroleStatus = AXCall.copyAttribute(element, kAXSubroleAttribute as CFString, &subroleValue)
        guard subroleStatus == .success,
              let subrole = subroleValue as? String,
              subrole == "AXUnknown" else {
            return false
        }

        guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
              let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString),
              let context = screenContexts[screenDisplayId] else {
            return false
        }

        let accessibilityFrame = CGRect(origin: position, size: size)
        let screenFrame = context.descriptor.accessibilityToScreen(accessibilityFrame)
        let screenWidth = context.descriptor.cocoaBounds.width

        if screenFrame.width == screenWidth {
            let screenIndex = screenContextStore.loggingIndex(for: screenDisplayId)
            Logger.debug(
                "FullScreenTracker: treating AXUnknown window as full-screen on screen \(screenIndex) " +
                    "(bundle \(bundleIdentifier), width \(screenFrame.width) == screen \(screenWidth))"
            )
            return true
        }

        return false
    }

    private func windowElements(for appElement: AXUIElement) -> [AXUIElement] {
        var windowsObject: CFTypeRef?
        let status = AXCall.copyAttribute(appElement, kAXWindowsAttribute as CFString, &windowsObject)
        guard status == .success, let windowsObject else {
            return []
        }

        if let windowElements = windowsObject as? [AXUIElement] {
            return windowElements
        }

        if CFGetTypeID(windowsObject) == CFArrayGetTypeID() {
            let array = unsafeBitCast(windowsObject, to: CFArray.self)
            let count = CFArrayGetCount(array)
            var elements: [AXUIElement] = []
            elements.reserveCapacity(count)
            for index in 0..<count {
                let rawElement = CFArrayGetValueAtIndex(array, index)
                let element = unsafeBitCast(rawElement, to: AXUIElement.self)
                elements.append(element)
            }
            return elements
        }

        return []
    }

    private func handleFullScreenPauseStateChange(for displayId: CGDirectDisplayID) {
        let isFullScreen = fullScreenTracker.isFullScreen(displayId: displayId)

        if isFullScreen {
            if launcherController.isActive,
               let targetScreenId = targetedScreenId(),
               targetScreenId == displayId {
                launcherController.hide()
                Logger.debug(
                    "Launcher: Hidden because screen \(screenContextStore.loggingIndex(for: displayId)) " +
                        "entered full-screen"
                )
            }
            if cmdTabController.isActive,
               let targetScreenId = targetedScreenId(),
               targetScreenId == displayId {
                cmdTabController.hideForExternalInterruption()
                Logger.debug(
                    "CmdTab: Hidden because screen \(screenContextStore.loggingIndex(for: displayId)) " +
                        "entered full-screen"
                )
            }

            placeholderCoordinator.clearPlaceholdersForScreen(displayId)
            targetedZoneManager.ensureTargetedZone(reason: "full-screen-entered")
            refreshIndicators()
            refreshResizeHandles()

            if launcherController.isActive,
               let targetScreenId = targetedScreenId(),
               isScreenPausedForFullScreen(targetScreenId) {
                launcherController.hide()
                Logger.debug("Launcher: Hidden because target screen entered full-screen")
            }
            if cmdTabController.isActive,
               let targetScreenId = targetedScreenId(),
               isScreenPausedForFullScreen(targetScreenId) {
                cmdTabController.hideForExternalInterruption()
                Logger.debug("CmdTab: Hidden because target screen entered full-screen")
            }
        } else {
            _ = placeTrackedButUnzonedWindowsAfterFullScreenExit(on: displayId)
            // Re-sync to restore placeholders and indicators on the screen that exited full-screen.
            syncWindowsToZones()
        }
    }

    /// Full-screen pause: when a screen exits full-screen mode, place any managed windows that
    /// were deferred on that screen. Spec: prefer lowest-index empty tiling zone on that screen;
    /// if none exists, place into that screen's floating zone.
    @discardableResult
    private func placeTrackedButUnzonedWindowsAfterFullScreenExit(on screenId: CGDirectDisplayID) -> Int {
        guard !isScreenPausedForFullScreen(screenId) else {
            return 0
        }

        let baseReason = "full-screen-exited"
        let placedCount = withTrackedButUnzonedWindows(
            reason: baseReason,
            candidateKind: "full-screen-exit",
            restrictedToScreenId: screenId,
            skipFullScreenPausedScreens: false,
            logSkipFullScreenPaused: false
        ) { window in
            let destination: TargetedZoneManager.TargetedDestination = {
                guard let controller = zoneController(for: screenId),
                      let emptyZone = controller.findEmptyZone() else {
                    return .floating(screenId: screenId)
                }
                return .tiled(ZoneKey(screenId: screenId, index: emptyZone.index))
            }()

            windowPlacementManager.placeWindow(
                window,
                into: destination,
                centerFloatingWindow: true,
                reason: "\(baseReason)-deferred-placement",
                retargetOnRemoval: true,
                forceRetargetAfterFill: false,
                logIfUnassignedOnRemoval: false
            )
        }

        if placedCount > 0 {
            Logger.debug("Full-screen exit placed \(placedCount) deferred window(s) on screen \(screenContextStore.loggingIndex(for: screenId))")
        }

        return placedCount
    }
}
