/// Launcher window switcher and application launcher integration
import AppKit

// MARK: - Launcher Target Change Handling

extension AppController {
    /// Called when the targeted destination changes.
    /// Maintains the invariant that the Launcher never remains visible while pointing at a non-targeted destination.
    func targetedZoneDidChange(from oldDestination: TargetedZoneManager.TargetedDestination?, to newDestination: TargetedZoneManager.TargetedDestination?) {
        // Invariant: the Launcher must never remain visible while pointing at a non-targeted destination.
        // If the target changes while the Launcher is open, either reposition it to the new target
        // (empty tiled / temporary) or hide it (occupied tiled / cleared target).
        if launcherController.isActive {
            guard let newDestination else {
                launcherController.hide()
                Logger.debug("Launcher: Hidden because target cleared")
                return
            }

            switch newDestination {
            case .temporary:
                launcherController.repositionToCurrentTarget()
                Logger.debug("Launcher: Repositioned for temporary target")
            case .tiled(let key):
                if targetedZoneManager.isZoneEmpty(key) {
                    launcherController.repositionToCurrentTarget()
                    Logger.debug("Launcher: Repositioned for empty target zone \(key.index)")
                } else {
                    launcherController.hide()
                    Logger.debug("Launcher: Hidden because target zone \(key.index) is occupied")
                }
            }
            return
        }

    }

    /// Auto-show Launcher if the currently targeted zone is an empty tiled zone.
    /// Called when:
    /// - A tiled zone becomes empty (window closed, minimized, or moved away)
    /// - After a zone is added
    /// - After clear/reset zones shortcut empties zones
    internal func autoShowLauncherIfEmptyTargetedTiledZone() {
        guard !launcherController.isActive,
              let targetedKey = targetedZoneKey,
              targetedZoneManager.isZoneEmpty(targetedKey) else {
            return
        }

        launcherController.autoShow()
        Logger.debug("Launcher: Auto-shown for empty zone \(targetedKey.index)")
    }
}

extension AppController: LauncherControllerDelegate {
    // MARK: - Window Selection

    func launcherController(_ controller: LauncherController, didSelectWindow window: LauncherWindowItem) {
        handleWindowSelection(window, activateInPlace: false)
    }

    /// Handles window selection from Launcher or DockMenu.
    ///
    /// - Parameters:
    ///   - window: The selected window item.
    ///   - activateInPlace: If true (DockMenus mode), windows already in a zone and not minimized
    ///     are activated without being moved to the targeted zone.
    internal func handleWindowSelection(_ window: LauncherWindowItem, activateInPlace: Bool) {
        // First, try to use the managed window if Zonogy already knows about it
        if let managedWindowId = window.managedWindowId,
           let managed = windowController.window(withId: managedWindowId) {

            // If activateInPlace: if window is already in a zone and not minimized, just activate it
            if activateInPlace && !managed.isMinimized && managed.zoneIndex != nil {
                Logger.debug("Launcher: window \(managedWindowId) already in zone, activating in place")
                activateWindow(managed)
                return
            }

            // Calculate target zone frame for pre-positioning
            let targetInfo = calculateTargetZoneFrame(for: managed)

            // Unminimize if needed - pre-position BEFORE unminimizing for smooth animation
            if managed.isMinimized {
                if let (frame, descriptor) = targetInfo {
                    prePositionMinimizedWindowForLauncher(managed, to: frame, on: descriptor)
                }
                // Suppress deminiaturized notification so it doesn't trigger re-placement
                suppressNextEvents(for: [managed.windowId], events: [.deminiaturized], reason: "launcher-unminimize")
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
        performDefaultLauncherAction(for: url)
    }

    /// Performs the default Launcher action for an app URL.
    /// - If the app is running with managed windows: selects preferred window (respecting hasMainWindow),
    ///   pre-positions if minimized, unminimizes, and places in targeted zone.
    /// - If the app is not running or has no managed windows: launches/activates the app.
    ///
    /// This is the shared code path used by both Launcher and DockMenus click interception.
    ///
    /// - Parameter activateInPlace: If true, windows already in a zone (not minimized) are activated
    ///   without being moved to the targeted zone. Used by DockMenus which doesn't support "moving"
    ///   windows between zones like the Launcher does.
    internal func performDefaultLauncherAction(for url: URL, activateInPlace: Bool = false) {
        // Check if app is already running - select the preferred window
        if let bundleId = Bundle(url: url)?.bundleIdentifier,
           let preferredWindow = preferredManagedWindowForRunningApp(bundleIdentifier: bundleId) {

            // If activateInPlace: if window is already in a zone and not minimized,
            // just activate it without moving
            if activateInPlace && !preferredWindow.isMinimized && isWindowInZone(preferredWindow) {
                Logger.debug("Launcher: window \(preferredWindow.windowId) already in zone, activating in place")
                activateWindow(preferredWindow)
                return
            }

            // Calculate target zone frame for pre-positioning
            let targetInfo = calculateTargetZoneFrame(for: preferredWindow)

            // Pre-position and unminimize if needed
            if preferredWindow.isMinimized {
                if let (frame, descriptor) = targetInfo {
                    prePositionMinimizedWindowForLauncher(preferredWindow, to: frame, on: descriptor)
                }
                // Suppress deminiaturized notification so it doesn't trigger re-placement
                suppressNextEvents(for: [preferredWindow.windowId], events: [.deminiaturized], reason: "launcher-unminimize")
                windowController.unminimizeWindow(preferredWindow)
            }

            // Place in targeted zone
            placeSelectedWindow(preferredWindow)
            return
        }

        // Normal app launch (not running, or no eligible windows)
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

    /// Returns true if the window is currently assigned to a tiling zone or temporary zone.
    private func isWindowInZone(_ window: ManagedWindow) -> Bool {
        if window.zoneIndex != nil {
            return true
        }
        return isWindowInTemporaryZone(window.windowId)
    }

    /// Returns the preferred window for a running app based on configuration:
    /// - If app has `hasMainWindow: true`: returns window with lowest Zonogy ID (first created)
    /// - Otherwise: returns the most recently active window
    /// - Returns nil if app has no managed windows with titles
    internal func preferredManagedWindowForRunningApp(bundleIdentifier: String) -> ManagedWindow? {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return nil
        }

        let pid = runningApp.processIdentifier

        // Collect all managed windows for this app (with valid titles)
        var eligibleWindows: [ManagedWindow] = []

        for window in windowController.allWindows {
            guard !window.isPlaceholder,
                  case .accessibility(let element, let windowPid, _) = window.backing,
                  windowPid == pid else {
                continue
            }

            // Check title (must have a title to be considered a real window)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, !title.isEmpty {
                eligibleWindows.append(window)
            }
        }

        guard !eligibleWindows.isEmpty else {
            return nil
        }

        // Check if this app prefers the "main window" (lowest Zonogy ID)
        let prefersMainWindow = configuration.applicationExceptionPolicy.hasMainWindow(forBundleIdentifier: bundleIdentifier)

        if prefersMainWindow {
            // Sort by Zonogy ID ascending (first created = main window)
            eligibleWindows.sort { $0.windowId < $1.windowId }
            Logger.debug("Launcher: App \(bundleIdentifier) has hasMainWindow=true, selecting window \(eligibleWindows[0].windowId) (lowest ID)")
        } else {
            // Sort by last active time descending (most recent first), with Zonogy ID as tiebreaker
            eligibleWindows.sort { lhs, rhs in
                let lhsTime = windowController.lastActiveTime(for: lhs.windowId)
                let rhsTime = windowController.lastActiveTime(for: rhs.windowId)

                switch (lhsTime, rhsTime) {
                case (let lhsT?, let rhsT?):
                    return lhsT > rhsT  // More recent first
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.windowId < rhs.windowId  // Fallback to Zonogy ID
                }
            }
            Logger.debug("Launcher: App \(bundleIdentifier) selecting most recent window \(eligibleWindows[0].windowId)")
        }

        return eligibleWindows.first
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

    internal func dismissLauncherIfActive() {
        guard launcherController.isActive else { return }
        launcherController.hide()
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

    func menuBarOwnerPid() -> pid_t? {
        // The nonactivatingPanel Launcher doesn't trigger app activation,
        // so lastActiveApplicationPid remains the menu bar owner
        return lastActiveApplicationPid
    }

    var launcherWindowProvider: LauncherWindowProvider {
        return self
    }

    // MARK: - Private Helpers

    private func placeSelectedWindow(_ managed: ManagedWindow) {
        // CAPTURE the original targeted zone BEFORE any modifications
        // (removeWindowFromAllZones with retarget:true would change the target to the emptied zone)
        let originalTargetedKey = targetedZoneKey
        let originalTemporaryTarget = targetedTemporaryScreenId

        // Remove from any current zone (WITHOUT retargeting - we'll handle it ourselves after placement)
        removeWindowFromAllZones(windowId: managed.windowId, reason: "launcher-placement", retarget: false)

        // If targeting the temporary zone, place there
        if let temporaryScreenId = originalTemporaryTarget {
            assignWindowToTemporaryZone(managed, on: temporaryScreenId, centerWindow: true, reason: "launcher-selection")
            Logger.debug("Launcher: Placed window \(managed.windowId) into temporary zone on screen \(temporaryScreenId)")
            // Sync to create placeholder for the now-empty source zone
            syncWindowsToZones()
            return
        }

        // Otherwise place in the originally targeted tiled zone
        guard let targetedKey = originalTargetedKey,
              let context = screenContexts[targetedKey.screenId],
              let descriptor = descriptor(for: targetedKey.screenId),
              let zone = context.zoneController.zone(at: targetedKey.index) else {
            // Fallback: just activate the window without moving it
            activateWindow(managed)
            return
        }

        // Check if zone was empty before (matching WindowPlacementManager.zoneWasEmptyBeforePlacement logic)
        // Zone is "empty" if no occupant or occupant is a placeholder
        let zoneWasEmpty: Bool
        if let existingId = zone.windowId,
           let existingWindow = windowController.window(withId: existingId) {
            zoneWasEmpty = existingWindow.isPlaceholder
        } else {
            zoneWasEmpty = true
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

        // Only retarget if zone was empty before (same condition as WindowPlacementManager.assignWindowToZone)
        if zoneWasEmpty {
            updateTemporaryZoneTargeting(reason: "launcher-placement")
            targetedZoneManager.retargetAfterFillingZone(targetedKey, reason: "launcher-filled")
        }

        Logger.debug("Launcher: Placed window \(managed.windowId) into zone \(targetedKey.index) on screen \(targetedKey.screenId)")

        // Activate the window
        activateWindow(managed)

        syncWindowsToZones()
        refreshIndicators()
    }

    /// Calculate the target zone frame for a window being placed via Launcher
    private func calculateTargetZoneFrame(for managed: ManagedWindow) -> (frame: CGRect, descriptor: ScreenDescriptor)? {
        // For temporary zone, calculate the centered frame
        if let temporaryScreenId = targetedTemporaryScreenId {
            guard let descriptor = descriptor(for: temporaryScreenId),
                  let frame = temporaryZoneCoordinator.computePlacementFrame(for: managed, on: temporaryScreenId) else {
                return nil
            }
            return (frame, descriptor)
        }

        // Calculate the targeted tiled zone frame
        targetedZoneManager.ensureTargetedZone(reason: "launcher-pre-position")
        guard let targetedKey = targetedZoneKey,
              let context = screenContexts[targetedKey.screenId],
              let descriptor = descriptor(for: targetedKey.screenId),
              let zone = context.zoneController.zone(at: targetedKey.index) else {
            return nil
        }

        let displayFrame = frameWithMargin(for: zone, in: context.zoneController)
        return (displayFrame, descriptor)
    }

    /// Pre-position a minimized window to the target zone frame before unminimizing
    /// This ensures the unminimize animation shows the window "restoring" to the correct position
    private func prePositionMinimizedWindowForLauncher(_ managed: ManagedWindow, to screenFrame: CGRect, on screen: ScreenDescriptor) {
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

        Logger.debug("Launcher: Pre-positioned minimized window \(managed.windowId) to \(screenFrame) before unminimizing")
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
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return []
        }

        let pid = runningApp.processIdentifier
        var items: [LauncherWindowItem] = []

        // Use Zonogy's tracked windows as the source of truth
        for window in windowController.allWindows {
            guard !window.isPlaceholder,
                  case .accessibility(let element, let windowPid, _) = window.backing,
                  windowPid == pid else {
                continue
            }

            // Get title from AX (not cached - titles change frequently)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            var title = (titleRef as? String) ?? ""
            guard !title.isEmpty else { continue }

            // Strip app name suffix (e.g., " - Safari", " — Finder")
            // Handles: hyphen (-), en-dash (–), em-dash (—), and pipe (|)
            if let appName = runningApp.localizedName {
                for separator in [" - ", " – ", " — ", " | "] {
                    let suffix = separator + appName
                    if title.hasSuffix(suffix) {
                        title = String(title.dropLast(suffix.count))
                        break
                    }
                }
            }

            let item = LauncherWindowItem(
                title: title,
                isMinimized: window.isMinimized,  // Use cached state
                axElement: element,
                lastActiveTime: windowController.lastActiveTime(for: window.windowId),
                bundleIdentifier: bundleIdentifier,
                pid: pid,
                managedWindowId: window.windowId
            )
            items.append(item)
        }

        // Sort by lastActiveTime (most recent first), then by Zonogy ID (discovery order)
        items.sort { lhs, rhs in
            switch (lhs.lastActiveTime, rhs.lastActiveTime) {
            case (let lhsTime?, let rhsTime?):
                return lhsTime > rhsTime
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                // Fall back to Zonogy ID (discovery order), which prioritizes main windows
                let lhsId = lhs.managedWindowId ?? Int.max
                let rhsId = rhs.managedWindowId ?? Int.max
                return lhsId < rhsId
            }
        }

        return items
    }

    func windowCount(for bundleIdentifier: String) -> Int {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return 0
        }

        let pid = runningApp.processIdentifier
        var count = 0

        // Use Zonogy's tracked windows as the source of truth
        for window in windowController.allWindows {
            guard !window.isPlaceholder,
                  case .accessibility(let element, let windowPid, _) = window.backing,
                  windowPid == pid else {
                continue
            }

            // Check title (still need AX for this - titles change)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, !title.isEmpty {
                count += 1
            }
        }

        return count
    }
}
