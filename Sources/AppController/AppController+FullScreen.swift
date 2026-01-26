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

    internal func isScreenPausedForFullScreen(_ screenId: CGDirectDisplayID) -> Bool {
        fullScreenTracker.isFullScreen(displayId: screenId)
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

        let resolvedDisplayId = screenDisplayIdHint ?? detectScreenId(for: element) ?? primaryScreenId
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
        let status = _AXUIElementGetWindow(element, &cgWindowId)
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
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
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
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
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
        } else {
            // Re-sync to restore placeholders and indicators on the screen that exited full-screen.
            syncWindowsToZones()
        }
    }
}
