/// Launcher window switcher and application launcher integration
import AppKit
import ApplicationServices

// MARK: - Launcher Target Change Handling

extension AppController {
    /// Called when the targeted destination changes.
    /// Maintains the invariant that the Launcher never remains visible while pointing at a non-targeted destination.
    /// CmdTab is dismissed when the target changes (it doesn't follow the target like the Launcher does).
    func targetedZoneDidChange(from oldDestination: TargetedZoneManager.TargetedDestination?, to newDestination: TargetedZoneManager.TargetedDestination?) {
        // Dismiss CmdTab when target changes - CmdTab is for quick window switching,
        // not zone placement, so it doesn't need to follow the target.
        if cmdTabController.isActive {
            cmdTabController.hideForExternalInterruption()
            Logger.debug("CmdTab: Hidden because targeted zone changed")
        }

        // Invariant: the Launcher must never remain visible while pointing at a non-targeted destination.
        // If the target changes while the Launcher is open, either reposition it to the new target
        // (empty tiled / floating) or hide it (occupied tiled / cleared target).
        if launcherController.isActive {
            if let session = launcherRetargetSession,
               newDestination != session.temporaryTarget {
                launcherRetargetSession = nil
            }

            guard let newDestination else {
                launcherController.hide()
                Logger.debug("Launcher: Hidden because target cleared")
                return
            }

            if let screenId = screenId(for: newDestination),
               isScreenPausedForFullScreen(screenId) {
                launcherController.hide()
                Logger.debug("Launcher: Hidden because target screen is full-screen")
                return
            }

            if launcherRetargetSession?.temporaryTarget == newDestination {
                launcherController.repositionToCurrentTarget()
                Logger.debug("Launcher: Repositioned for temporary retarget")
                return
            }

            switch newDestination {
            case .floating:
                launcherController.repositionToCurrentTarget()
                Logger.debug("Launcher: Repositioned for floating target")
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

    private func canShowLauncherOnCurrentTarget() -> Bool {
        guard let screenId = targetedScreenId() else {
            return false
        }
        return !isScreenPausedForFullScreen(screenId)
    }

    internal func showLauncherIfAllowed(trigger: String, autoShow: Bool = false) {
        guard !launcherController.isActive else {
            return
        }
        guard canShowLauncherOnCurrentTarget() else {
            Logger.debug("Launcher: Suppressed due to full-screen target (trigger: \(trigger))")
            return
        }

        if autoShow {
            launcherController.autoShow()
        } else {
            launcherController.show()
        }
    }

    /// Auto-show Launcher if the currently targeted zone is an empty tiled zone.
    /// Called when:
    /// - A tiled zone becomes empty (window closed, minimized, or moved away)
    /// - After a zone is added
    /// - After clear/reset zones shortcut empties zones
    /// - Only when the "Auto-show Launcher for empty tiling zones" preference is enabled
    /// - Not when an unmanaged window has focus on the targeted zone's screen
    internal func autoShowLauncherIfEmptyTargetedTiledZone() {
        guard autoShowLauncherForEmptyTilingZonesEnabled,
              !launcherController.isActive,
              case .tiled(let targetedKey) = targetedZoneManager.targetedDestination,
              targetedZoneManager.isZoneEmpty(targetedKey) else {
            return
        }

        guard canShowLauncherOnCurrentTarget() else {
            Logger.debug("Launcher: Skipping auto-show because target screen is full-screen")
            return
        }

        // Don't auto-show if the targeted zone's screen has an unmanaged focused window
        if unmanagedFocusedWindowScreenId == targetedKey.screenId {
            Logger.debug("Launcher: Skipping auto-show because unmanaged window has focus on screen \(screenContextStore.loggingIndex(for: targetedKey.screenId))")
            return
        }

        launcherController.autoShow()
        Logger.debug("Launcher: Auto-shown for empty zone \(targetedKey.index)")
    }

    /// Dismiss the Launcher unless it's in its auto-show grace period.
    /// Use for focus-based dismissals to avoid immediate hide due to macOS auto-focus after close/minimize.
    @discardableResult
    internal func dismissLauncherIfActiveRespectingAutoShowGrace() -> Bool {
        guard launcherController.isActive, !launcherController.isInAutoShowGracePeriod else {
            return false
        }
        launcherController.hide()
        return true
    }

    internal func retargetOpenLauncherToActiveWindowIfNeeded(reason: String) {
        let currentTarget = targetedZoneManager.targetedDestination
        let resolvedTarget = resolvedRepeatedLauncherShortcutTargetUsingActiveWindow()

        guard let temporaryTarget = resolvedTarget,
              temporaryTarget != currentTarget else {
            return
        }

        if let session = launcherRetargetSession {
            launcherRetargetSession = TemporaryRetargetSession(
                originalTarget: session.originalTarget,
                temporaryTarget: temporaryTarget
            )
        } else {
            launcherRetargetSession = TemporaryRetargetSession(
                originalTarget: currentTarget,
                temporaryTarget: temporaryTarget
            )
        }

        applyTargetedDestination(temporaryTarget, reason: reason)
    }

    internal func restoreLauncherOriginalTargetIfNeeded(reason: String) {
        guard let session = launcherRetargetSession else {
            return
        }

        launcherRetargetSession = nil

        guard session.shouldRestoreOriginalTarget(
            currentTarget: targetedZoneManager.targetedDestination
        ) else {
            return
        }

        applyTargetedDestination(session.originalTarget, reason: reason)
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

            // If activateInPlace: if window is already in a zone (tiling or floating), just activate it
            if activateInPlace && managed.isPlacedInZone {
                Logger.debug("Launcher: window \(managedWindowId) already in zone, activating in place")
                activateWindow(managed)
                return
            }

            let destination = launcherSelectionDestination(for: managed)
            let targetInfo = destination.flatMap { calculateTargetZoneFrame(for: managed, destination: $0) }

            // Unminimize if needed - pre-position BEFORE unminimizing for smooth animation
            if !managed.isPlacedInZone {
                if let (frame, descriptor) = targetInfo {
                    prePositionMinimizedWindowForLauncher(managed, to: frame, on: descriptor)
                }
                // Suppress deminiaturized notification so it doesn't trigger re-placement
                suppressNextEvents(for: [managed.windowId], events: [.deminiaturized], reason: "launcher-unminimize")
                windowController.unminimizeWindow(managed)
            }
            // Place in targeted zone
            placeSelectedWindow(managed, destination: destination)
            return
        }

        // Window no longer tracked (removed between item construction and selection) -
        // focus via Accessibility API and let Zonogy recapture it
        focusWindowViaAccessibility(window)
    }

    private func focusWindowViaAccessibility(_ window: LauncherWindowItem) {
        // Unminimize if needed (based on last known state when item was constructed)
        if !window.isPlacedInZone {
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
    /// - Parameters:
    ///   - activateInPlace: If true, windows already in a zone (not minimized) are activated
    ///     without being moved to the targeted zone. Used by DockMenus which doesn't support "moving"
    ///     windows between zones like the Launcher does.
    ///   - dockItemElement: Optional Dock item accessibility element. When provided and the app has
    ///     no managed windows, we simulate a press on the Dock item instead of using NSWorkspace,
    ///     which triggers the app's native "clicked in Dock" behavior (typically creating a new window).
    internal func performDefaultLauncherAction(for url: URL, activateInPlace: Bool = false, dockItemElement: AXUIElement? = nil) {
        // Check if app is already running - select the preferred window
        if let bundleId = ApplicationIdentity.bundleIdentifier(forApplicationURL: url),
           let preferredWindow = preferredManagedWindowForRunningApp(bundleIdentifier: bundleId) {

            // If activateInPlace: if window is already in a zone, just activate it without moving
            if activateInPlace && preferredWindow.isPlacedInZone {
                Logger.debug("Launcher: window \(preferredWindow.windowId) already in zone, activating in place")
                activateWindow(preferredWindow)
                return
            }

            let destination = launcherSelectionDestination(for: preferredWindow)
            let targetInfo = destination.flatMap { calculateTargetZoneFrame(for: preferredWindow, destination: $0) }

            // Pre-position and unminimize if needed
            if !preferredWindow.isPlacedInZone {
                if let (frame, descriptor) = targetInfo {
                    prePositionMinimizedWindowForLauncher(preferredWindow, to: frame, on: descriptor)
                }
                // Suppress deminiaturized notification so it doesn't trigger re-placement
                suppressNextEvents(for: [preferredWindow.windowId], events: [.deminiaturized], reason: "launcher-unminimize")
                windowController.unminimizeWindow(preferredWindow)
            }

            // Place in targeted zone
            placeSelectedWindow(preferredWindow, destination: destination)
            return
        }

        // No managed windows (app may be running or not): simulate Dock item press if element available
        // This triggers the app's native "clicked in Dock" behavior (launches app or creates new window)
        if let dockItemElement {
            Logger.debug("Launcher: No managed windows, simulating Dock item press for \(url.lastPathComponent)")
            AXUIElementPerformAction(dockItemElement, kAXPressAction as CFString)
            return
        }

        // Normal app launch (not running, or no eligible windows and no Dock element)
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

    /// Returns the preferred window for a running app based on configuration:
    /// - If app has `hasMainWindow: true`: returns window with lowest CGWindowID
    /// - Otherwise: returns the same window as selecting the app, drilling into window list, and opening
    ///   the first window row (not-in-zone first, then recency)
    /// - Returns nil if app has no managed windows with titles
    internal func preferredManagedWindowForRunningApp(bundleIdentifier: String) -> ManagedWindow? {
        guard let runningApp = ApplicationIdentity.runningApplication(bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let pid = runningApp.processIdentifier

        // Collect all managed windows for this app (with valid titles)
        var eligibleWindows: [ManagedWindow] = []

        for window in windowController.allWindows {
            guard window.backing.pid == pid else {
                continue
            }

            // Check title (must have a title to be considered a real window)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window.backing.element, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, !title.isEmpty {
                eligibleWindows.append(window)
            }
        }

        guard !eligibleWindows.isEmpty else {
            return nil
        }

        // Check if this app prefers the "main window" (lowest CGWindowID)
        let prefersMainWindow = windowController.applicationExceptionPolicy.hasMainWindow(forBundleIdentifier: bundleIdentifier)

        let candidates = eligibleWindows.map { window in
            PreferredWindowSelection.Candidate(
                windowId: window.windowId,
                cgWindowId: window.backing.cgWindowId,
                isPlacedInZone: window.isPlacedInZone,
                lastActiveTime: windowController.lastActiveTime(for: window.windowId)
            )
        }

        guard let selected = PreferredWindowSelection.selectPreferredWindow(from: candidates, prefersMainWindow: prefersMainWindow) else {
            return nil
        }

        if prefersMainWindow {
            Logger.debug("Launcher: App \(bundleIdentifier) has hasMainWindow=true, selecting window \(selected.windowId) (lowest CGWindowID \(selected.cgWindowId))")
        } else {
            Logger.debug("Launcher: App \(bundleIdentifier) selecting first drill-down window \(selected.windowId) (not-in-zone first, then recency)")
        }

        let windowsById = Dictionary(uniqueKeysWithValues: eligibleWindows.map { ($0.windowId, $0) })
        return windowsById[selected.windowId]
    }

    // MARK: - App Activation (without changing window placement)

    func launcherController(_ controller: LauncherController, didActivateApp bundleIdentifier: String) {
        guard let app = ApplicationIdentity.runningApplication(bundleIdentifier: bundleIdentifier) else {
            Logger.debug("Launcher: Cannot find running app with bundle ID \(bundleIdentifier)")
            return
        }

        app.activate(options: [.activateIgnoringOtherApps])
        Logger.debug("Launcher: Activated app \(bundleIdentifier)")
    }

    // MARK: - Zone Removal

    func launcherControllerDidRequestRemoveZone(_ controller: LauncherController) {
        guard let key = targetedZoneKey else { return }
        if let context = screenContexts[key.screenId],
           context.zoneController.allZones.count > 1 {
            Logger.debug("Launcher: Removing targeted zone \(key.index) on screen \(screenContextStore.loggingIndex(for: key.screenId))")
            _ = performRemoveZone(at: key.index, on: key.screenId, announce: false)
        } else {
            Logger.debug("Launcher: Only 1 zone, hiding Launcher")
            launcherController.hide()
        }
    }

    // MARK: - Dismissal

    func launcherControllerDidCancel(_ controller: LauncherController) {
        Logger.debug("Launcher: Cancelled")
        restoreLauncherOriginalTargetIfNeeded(reason: "launcher-cancelled")
    }

    func launcherControllerDidDismiss(_ controller: LauncherController) {
        launcherRetargetSession = nil
        Logger.debug("Launcher: Dismissed")
    }

    internal func dismissLauncherIfActive() {
        guard launcherController.isActive else { return }
        launcherController.hide()
    }

    // MARK: - Zone Frame

    func targetedZoneFrame() -> (CGRect, ScreenDescriptor)? {
        // If targeting a tiled zone, return its frame
        if case .tiled(let targetedKey) = targetedZoneManager.targetedDestination,
           let context = screenContexts[targetedKey.screenId],
           let zone = context.zoneController.zone(at: targetedKey.index) {
            let frame = frameWithMargin(for: zone, in: context.zoneController)
            return (frame, context.descriptor)
        }

        return nil
    }

    func targetedScreenId() -> CGDirectDisplayID? {
        // Return the targeted screen (floating zone screen or tiled zone screen)
        if let destination = targetedZoneManager.targetedDestination,
           let screenId = screenId(for: destination) {
            return screenId
        }
        return activeScreenId()
    }

    private func screenId(for destination: TargetedZoneManager.TargetedDestination) -> CGDirectDisplayID? {
        switch destination {
        case .floating(let screenId):
            return screenId
        case .tiled(let key):
            return key.screenId
        }
    }

    func menuBarOwnerPid() -> pid_t? {
        // The nonactivatingPanel Launcher doesn't trigger app activation,
        // so lastActiveApplicationPid remains the menu bar owner.
        // If Zonogy itself is frontmost, there is no external menu bar owner to target.
        guard let pid = lastActiveApplicationPid,
              pid != getpid() else {
            return nil
        }
        return pid
    }

    var launcherWindowProvider: LauncherWindowProvider {
        return self
    }

    // MARK: - Private Helpers

    private func placeSelectedWindow(
        _ managed: ManagedWindow,
        destination: TargetedZoneManager.TargetedDestination?
    ) {
        guard let destination else {
            activateWindow(managed)
            return
        }

        var didActivateInPlacement = false
        let afterPlacementAction: (() -> Void)?
        switch destination {
        case .floating:
            afterPlacementAction = nil
        case .tiled:
            afterPlacementAction = {
                didActivateInPlacement = true
                self.activateWindow(managed)
            }
        }

        windowPlacementManager.placeWindow(
            managed,
            into: destination,
            centerFloatingWindow: true,
            reason: "launcher-selection",
            retargetOnRemoval: false,
            forceRetargetAfterFill: false,
            afterPlacementAction: afterPlacementAction
        )

        switch destination {
        case .floating:
            // Sync to create placeholder for the now-empty source zone.
            syncWindowsToZones(recentlyPlacedInFloatingZone: managed.windowId)
            return
        case .tiled:
            break
        }

        if !didActivateInPlacement {
            activateWindow(managed)
        }
        // Placement already applied the target frame; sync will consume placement
        // bookkeeping and skip one immediate geometry reapply for this window.
        syncWindowsToZones()
    }

    private func launcherSelectionDestination(for managed: ManagedWindow) -> TargetedZoneManager.TargetedDestination? {
        targetedZoneManager.ensureTargetedZone(reason: "launcher-selection")
        return targetedZoneManager.targetedDestination
    }

    /// Place a window into a specific zone (used by DockMenu drag-and-drop).
    /// Unlike placeSelectedWindow, this takes an explicit zone key rather than using the targeted zone.
    internal func placeWindowIntoZone(_ managed: ManagedWindow, zoneKey: ZoneKey) {
        var didActivateInPlacement = false
        windowPlacementManager.placeWindow(
            managed,
            into: .tiled(zoneKey),
            centerFloatingWindow: true,
            reason: "dockmenu-drag-placement",
            retargetOnRemoval: false,
            forceRetargetAfterFill: true,
            afterPlacementAction: {
                didActivateInPlacement = true
                self.activateWindow(managed)
            }
        )

        if !didActivateInPlacement {
            activateWindow(managed)
        }
        syncWindowsToZones()
    }

    /// Calculate the placement frame for a window being placed via Launcher.
    private func calculateTargetZoneFrame(
        for managed: ManagedWindow,
        destination: TargetedZoneManager.TargetedDestination
    ) -> (frame: CGRect, descriptor: ScreenDescriptor)? {
        switch destination {
        case .floating(let screenId):
            guard let descriptor = descriptor(for: screenId),
                  let frame = floatingZoneCoordinator.computePlacementFrame(for: managed, on: screenId) else {
                return nil
            }
            return (frame, descriptor)
        case .tiled(let targetedKey):
            guard let context = screenContexts[targetedKey.screenId],
                  let descriptor = descriptor(for: targetedKey.screenId),
                  let zone = context.zoneController.zone(at: targetedKey.index) else {
                return nil
            }
            let displayFrame = frameWithMargin(for: zone, in: context.zoneController)
            return (displayFrame, descriptor)
        }
    }

    /// Pre-position a minimized window to the target zone frame before unminimizing
    /// This ensures the unminimize animation shows the window "restoring" to the correct position
    private func prePositionMinimizedWindowForLauncher(_ managed: ManagedWindow, to screenFrame: CGRect, on screen: ScreenDescriptor) {
        let effectiveScreenFrame = windowController.resolvedTargetScreenFrame(
            for: managed,
            requestedFrame: screenFrame,
            on: screen
        )
        let element = managed.backing.element
        let accessibilityFrame = screen.screenToAccessibility(effectiveScreenFrame)

        var position = accessibilityFrame.origin
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        }

        var size = accessibilityFrame.size
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }

        Logger.debug("Launcher: Pre-positioned minimized window \(managed.windowId) to \(effectiveScreenFrame) before unminimizing")
    }

    private func activateWindow(_ managed: ManagedWindow) {
        // Record activity immediately for reliable recency tracking (don't rely on AX notification)
        recordActiveWindowForHistory(windowId: managed.windowId, reason: "launcher-activate")
        raiseWindow(managed)
    }
}

// MARK: - LauncherWindowProvider

extension AppController: LauncherWindowProvider {
    func windowsForApp(bundleIdentifier: String) -> [LauncherWindowItem] {
        guard let runningApp = ApplicationIdentity.runningApplication(bundleIdentifier: bundleIdentifier) else {
            return []
        }

        let pid = runningApp.processIdentifier
        var items: [LauncherWindowItem] = []

        // Use Zonogy's tracked windows as the source of truth, already ordered by shared recency semantics.
        for window in windowController.allWindowsOrderedByRecency() {
            guard window.backing.pid == pid else {
                continue
            }
            let element = window.backing.element

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
                isPlacedInZone: window.isPlacedInZone,
                axElement: element,
                lastActiveTime: windowController.lastActiveTime(for: window.windowId),
                bundleIdentifier: bundleIdentifier,
                pid: pid,
                managedWindowId: window.windowId
            )
            items.append(item)
        }

        return items
    }

    func windowCount(for bundleIdentifier: String) -> Int {
        guard let runningApp = ApplicationIdentity.runningApplication(bundleIdentifier: bundleIdentifier) else {
            return 0
        }

        let pid = runningApp.processIdentifier
        var count = 0

        // Use Zonogy's tracked windows as the source of truth
        for window in windowController.allWindows {
            guard window.backing.pid == pid else {
                continue
            }

            // Check title (still need AX for this - titles change)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window.backing.element, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, !title.isEmpty {
                count += 1
            }
        }

        return count
    }

    func isDefaultWindowInZone(forBundleIdentifier bundleId: String) -> Bool {
        guard let preferredWindow = preferredManagedWindowForRunningApp(bundleIdentifier: bundleId) else {
            return false
        }
        return preferredWindow.isPlacedInZone
    }
}
