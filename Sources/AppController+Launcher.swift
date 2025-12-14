/// Launcher window switcher and application launcher integration
import AppKit

extension AppController: LauncherControllerDelegate {
    // MARK: - Window Selection

    func launcherController(_ controller: LauncherController, didSelectWindow window: LauncherWindowItem) {
        // First, try to use the managed window if Zonogy already knows about it
        if let managedWindowId = window.managedWindowId,
           let managed = windowController.window(withId: managedWindowId) {
            // Unminimize if needed
            if managed.isMinimized {
                windowController.unminimizeWindow(managed)
            }
            // Place in targeted zone
            placeSelectedWindow(managed)
            return
        }

        // Window not managed by Zonogy - focus it via Accessibility API and let Zonogy capture it
        focusWindowViaAccessibility(window)
    }

    private func focusWindowViaAccessibility(_ window: LauncherWindowItem) {
        // Unminimize if needed
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }

        // Make it the main window and raise it
        AXUIElementSetAttributeValue(window.axElement, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(window.axElement, kAXRaiseAction as CFString)

        // Activate the application
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        Logger.debug("Launcher: Focused window via accessibility (not yet managed by Zonogy)")
    }

    // MARK: - App Launch

    func launcherController(_ controller: LauncherController, didLaunchApp url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error = error {
                Logger.debug("Launcher: Failed to launch app at \(url.path): \(error.localizedDescription)")
            } else if let app = app {
                Logger.debug("Launcher: Launched \(app.localizedName ?? url.lastPathComponent)")
            }
        }
    }

    // MARK: - App Activation (without changing window placement)

    func launcherController(_ controller: LauncherController, didActivateApp bundleIdentifier: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            Logger.debug("Launcher: Cannot find running app with bundle ID \(bundleIdentifier)")
            return
        }

        app.activate(options: [.activateIgnoringOtherApps])
        Logger.debug("Launcher: Activated app \(bundleIdentifier)")
    }

    // MARK: - Dismissal

    func launcherControllerDidDismiss(_ controller: LauncherController) {
        Logger.debug("Launcher: Dismissed")
    }

    // MARK: - Zone Frame

    func targetedZoneFrame() -> (CGRect, ScreenDescriptor)? {
        // If targeting a tiled zone, return its frame
        if let targetedKey = targetedZoneKey,
           let context = screenContexts[targetedKey.screenId],
           let zone = context.zoneController.zone(at: targetedKey.index) {
            let frame = frameWithMargin(for: zone, in: context.zoneController)
            return (frame, context.descriptor)
        }

        return nil
    }

    func targetedScreenId() -> CGDirectDisplayID? {
        // Return the targeted screen (temporary zone screen or tiled zone screen)
        if let temporaryScreenId = targetedTemporaryScreenId {
            return temporaryScreenId
        }
        if let targetedKey = targetedZoneKey {
            return targetedKey.screenId
        }
        return activeScreenId()
    }

    var launcherWindowProvider: LauncherWindowProvider {
        return self
    }

    // MARK: - Private Helpers

    private func placeSelectedWindow(_ managed: ManagedWindow) {
        // Remove from any current zone
        removeWindowFromAllZones(windowId: managed.windowId, reason: "launcher-placement", retarget: true)

        // If targeting the temporary zone, place there
        if let temporaryScreenId = targetedTemporaryScreenId {
            assignWindowToTemporaryZone(managed, on: temporaryScreenId, centerWindow: true, reason: "launcher-selection")
            Logger.debug("Launcher: Placed window \(managed.windowId) into temporary zone on screen \(temporaryScreenId)")
            return
        }

        // Otherwise place in the targeted tiled zone
        targetedZoneManager.ensureTargetedZone(reason: "launcher-placement")
        guard let targetedKey = targetedZoneKey,
              let context = screenContexts[targetedKey.screenId],
              let descriptor = descriptor(for: targetedKey.screenId),
              let zone = context.zoneController.zone(at: targetedKey.index) else {
            // Fallback: just activate the window without moving it
            activateWindow(managed)
            return
        }

        // Displace any existing occupant
        if let existingId = zone.windowId,
           existingId != managed.windowId,
           let existingWindow = windowController.window(withId: existingId) {
            context.zoneController.removeWindow(windowId: existingId)
            if existingWindow.isPlaceholder {
                windowController.closeWindow(existingWindow)
                forgetPlaceholder(windowId: existingWindow.windowId)
            } else {
                clearManagedWindowZone(existingWindow)
                minimizeWindowProgrammatically(existingWindow, reason: "launcher-displaced")
            }
        }

        // Assign to zone
        context.zoneController.assignWindow(windowId: managed.windowId, toZoneIndex: targetedKey.index)
        let displayFrame = frameWithMargin(for: zone, in: context.zoneController)
        windowController.showWindow(managed, at: displayFrame, on: descriptor)
        setManagedWindow(managed, screenId: targetedKey.screenId, zoneIndex: targetedKey.index)

        // Update targeting to next empty zone
        updateTemporaryZoneTargeting(reason: "launcher-placement")
        let nextEmpty = targetedZoneManager.lowestIndexEmptyZoneOnSameScreen(
            screenId: targetedKey.screenId,
            excluding: targetedKey
        )
        if let nextEmpty {
            targetedZoneManager.setTargetedZone(nextEmpty, reason: "launcher-filled-zone")
        } else {
            targetedZoneManager.setTemporaryTarget(on: targetedKey.screenId, reason: "launcher-filled-no-empty")
        }

        Logger.debug("Launcher: Placed window \(managed.windowId) into zone \(targetedKey.index) on screen \(targetedKey.screenId)")

        // Activate the window
        activateWindow(managed)

        syncWindowsToZones()
        refreshIndicators()
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

// MARK: - LauncherWindowProvider

extension AppController: LauncherWindowProvider {
    func windowsForApp(bundleIdentifier: String) -> [LauncherWindowItem] {
        // Find the running app
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return []
        }

        let pid = runningApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get all windows via Accessibility API
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windowElements = windowsRef as? [AXUIElement] else {
            return []
        }

        // Build a lookup of managed windows by their AXUIElement for matching
        var managedWindowsByElement: [AccessibilityElementKey: ManagedWindow] = [:]
        for window in windowController.allWindows {
            guard !window.isPlaceholder else { continue }
            if case .accessibility(let element, let windowPid, _) = window.backing, windowPid == pid {
                let key = AccessibilityElementKey(element: element)
                managedWindowsByElement[key] = window
            }
        }

        var items: [LauncherWindowItem] = []

        for windowElement in windowElements {
            // Get title
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            // Skip windows with empty titles
            guard !title.isEmpty else { continue }

            // Get minimized state
            var minimizedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(windowElement, kAXMinimizedAttribute as CFString, &minimizedRef)
            let isMinimized = (minimizedRef as? Bool) ?? false

            // Check if this window is managed by Zonogy
            let elementKey = AccessibilityElementKey(element: windowElement)
            let managedWindow = managedWindowsByElement[elementKey]
            let lastActiveTime = managedWindow.flatMap { windowController.lastActiveTime(for: $0.windowId) }

            let item = LauncherWindowItem(
                title: title,
                isMinimized: isMinimized,
                axElement: windowElement,
                lastActiveTime: lastActiveTime,
                bundleIdentifier: bundleIdentifier,
                pid: pid,
                managedWindowId: managedWindow?.windowId
            )
            items.append(item)
        }

        // Sort by lastActiveTime (most recent first), with untracked windows at the bottom sorted alphabetically
        items.sort { lhs, rhs in
            switch (lhs.lastActiveTime, rhs.lastActiveTime) {
            case (let lhsTime?, let rhsTime?):
                return lhsTime > rhsTime  // Most recent first
            case (.some, .none):
                return true  // lhs has time, rhs doesn't - lhs comes first
            case (.none, .some):
                return false  // rhs has time, lhs doesn't - rhs comes first
            case (.none, .none):
                // Neither has time - sort alphabetically
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }

        return items
    }

    func windowCount(for bundleIdentifier: String) -> Int {
        // Find the running app
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return 0
        }

        let pid = runningApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get all windows via Accessibility API
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windowElements = windowsRef as? [AXUIElement] else {
            return 0
        }

        // Count windows with non-empty titles
        var count = 0
        for windowElement in windowElements {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, !title.isEmpty {
                count += 1
            }
        }

        return count
    }
}
