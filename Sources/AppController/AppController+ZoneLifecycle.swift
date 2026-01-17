import Foundation
import AppKit
import ApplicationServices

/// Zone lifecycle: window commands, resize handle delegation, event suppression, and programmatic minimize.
extension AppController {

    // MARK: - Window Management

    func closeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        removeWindowFromAllZones(windowId: windowId, reason: "close-command")

        // Close the window
        windowController.closeWindow(managed)

        // Sync to create placeholder if needed
        syncWindowsToZones()

        print("Closed window \(windowId)")
    }

    func minimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        let emptiedZoneKey = zoneKey(forManagedWindow: managed)

        let wasManualResizeDetached = performProgrammaticMinimizeCleanup(
            managed,
            minimizeReason: "minimize-command",
            cleanupReason: "minimize-command",
            retarget: true
        )
        syncWindowsToZones()
        scheduleMinimizeVerification(
            windowId: managed.windowId,
            emptiedZoneKey: emptiedZoneKey,
            minimizeReason: "minimize-command",
            cleanupReason: "minimize-command",
            wasManualResizeDetached: wasManualResizeDetached
        )

        print("Minimized window \(windowId)")
    }

    func unminimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        windowController.unminimizeWindow(managed)

        // Place the window using normal placement logic
        windowPlacementManager.placeNewWindow(managed)

        print("Unminimized window \(windowId)")
    }

    func captureFrontmostWindow() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            print("Frontmost application \(bundleId) is configured to be ignored.")
            return
        }

        guard let managed = windowController.captureFrontmostWindow() else {
            print("No frontmost window available. Make sure Accessibility permissions are granted and another app has a visible window.")
            return
        }

        if let key = zoneKey(forManagedWindow: managed),
           let context = screenContexts[key.screenId],
           let zone = context.zoneController.zone(at: key.index),
           zone.occupantWindowId == managed.windowId {
            syncWindowsToZones()
            print("Window \(managed.windowId) is already managed in zone \(key.index)")
            return
        }

        windowPlacementManager.placeNewWindow(managed)
        print("Captured window \(managed.windowId)")
    }

    // MARK: - ZoneResizeHandleManagerDelegate

    internal func beginZoneResizeDrag(screenId: CGDirectDisplayID, separatorIndex: Int) {
        Logger.debug("Zone resize drag began on \(screenContextStore.logDescription(for: screenId)) separator \(separatorIndex)")
        zoneResizeDragInProgress = true
        activeFitZoneResizeLoggedWindowIds.removeAll()
        // Return any window in reveal mode to rest mode before live resizing.
        exitRevealMode(reason: "zone-resize-begin")
    }

    internal func endZoneResizeDrag(screenId: CGDirectDisplayID, separatorIndex: Int) {
        Logger.debug("Zone resize drag ended on \(screenContextStore.logDescription(for: screenId)) separator \(separatorIndex)")
        zoneResizeDragInProgress = false
        activeFitZoneResizeLoggedWindowIds.removeAll()

        // When resizing stops, if the active window qualifies, re-evaluate ActiveFit.
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        handleActiveFitActivationCandidate(pid: pid)
    }

    func resizeHandleDragBegan(screenId: CGDirectDisplayID, separatorIndex: Int) {
        beginZoneResizeDrag(screenId: screenId, separatorIndex: separatorIndex)
    }

    func resizeHandleDragged(screenId: CGDirectDisplayID, separatorIndex: Int, delta: CGPoint) {
        guard let context = screenContexts[screenId] else { return }

        let separators = context.zoneController.separators()
        guard let separator = separators.first(where: { $0.index == separatorIndex }) else { return }

        let scalarDelta: CGFloat
        switch separator.orientation {
        case .vertical:
            scalarDelta = delta.x
        case .horizontal:
            scalarDelta = delta.y
        }

        guard abs(scalarDelta) > 0.001 else { return }

        // Apply resize
        context.zoneController.resizeBySeparator(index: separatorIndex, delta: scalarDelta)

        // Sync windows and handles to new layout
        syncWindowsToZones()
    }

    func resizeHandleDragEnded(screenId: CGDirectDisplayID, separatorIndex: Int) {
        endZoneResizeDrag(screenId: screenId, separatorIndex: separatorIndex)
    }

    // MARK: - Event suppression helpers

    /// Suppress the next `count` occurrences of the given events for specific windows. Entries self-expire after `timeout`.
    internal func suppressNextEvents(
        for windowIds: [Int],
        events: Set<AppController.SuppressedEvent>,
        count: Int,
        timeout: TimeInterval = 3.0,
        reason: String
    ) {
        guard !windowIds.isEmpty, !events.isEmpty, count > 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        for windowId in windowIds {
            var suppressions = eventSuppressions[windowId] ?? [:]
            for event in events {
                suppressions[event] = SuppressionEntry(remaining: count, deadline: deadline)
            }
            eventSuppressions[windowId] = suppressions
        }
        let eventList = events.map { $0.rawValue }.joined(separator: ",")
        Logger.debug(
            "Suppressing next \(count) event(s) [\(eventList)] for windows \(windowIds) until \(deadline) (reason: \(reason))"
        )
    }

    /// Convenience overload for suppressing the next single occurrence of a set of events.
    internal func suppressNextEvents(
        for windowIds: [Int],
        events: Set<AppController.SuppressedEvent>,
        timeout: TimeInterval = 3.0,
        reason: String
    ) {
        suppressNextEvents(for: windowIds, events: events, count: 1, timeout: timeout, reason: reason)
    }

    internal func isEventSuppressed(windowId: Int, event: AppController.SuppressedEvent) -> Bool {
        let now = Date()
        guard var suppressions = eventSuppressions[windowId],
              var entry = suppressions[event] else {
            return false
        }

        if entry.deadline < now || entry.remaining <= 0 {
            suppressions.removeValue(forKey: event)
            if suppressions.isEmpty {
                eventSuppressions.removeValue(forKey: windowId)
            } else {
                eventSuppressions[windowId] = suppressions
            }
            return false
        }

        entry.remaining -= 1
        suppressions[event] = entry.remaining > 0 ? entry : nil
        if suppressions[event] == nil {
            suppressions.removeValue(forKey: event)
        }
        if suppressions.isEmpty {
            eventSuppressions.removeValue(forKey: windowId)
        } else {
            eventSuppressions[windowId] = suppressions
        }

        Logger.debug("Suppressed event \(event.rawValue) for window \(windowId)")
        return true
    }

    // MARK: - Programmatic actions

    internal func minimizeWindowProgrammatically(
        _ managed: ManagedWindow,
        reason: String,
        suppressTimeout: TimeInterval = 3.0
    ) {
        suppressNextEvents(for: [managed.windowId], events: [.miniaturized], timeout: suppressTimeout, reason: reason)
        windowController.minimizeWindow(managed)
    }

    @discardableResult
    internal func performProgrammaticMinimizeCleanup(
        _ managed: ManagedWindow,
        minimizeReason: String,
        cleanupReason: String,
        retarget: Bool = true
    ) -> Bool {
        let wasManualResizeDetached = manualResizeDetachedWindowIds.contains(managed.windowId)
        minimizeWindowProgrammatically(managed, reason: minimizeReason)
        manualResizeDetachedWindowIds.remove(managed.windowId)
        removeWindowFromAllZones(windowId: managed.windowId, reason: cleanupReason, retarget: retarget)
        return wasManualResizeDetached
    }

    internal func finalizeProgrammaticMinimize(
        windowId: Int,
        emptiedZoneKey: ZoneKey?,
        reason: String
    ) {
        // Note: emptiedZoneKey is no longer used - temporary zone promotion is now
        // handled centrally by syncWindowsToZones. Keeping parameter for API stability.
        _ = emptiedZoneKey

        clearRevealModeForWindow(windowId: windowId, transitionToRest: false, reason: reason)
        activeFitClearSuppressionForWindow(windowId)
    }

    internal func scheduleMinimizeVerification(
        windowId: Int,
        emptiedZoneKey: ZoneKey?,
        minimizeReason: String,
        cleanupReason: String,
        wasManualResizeDetached: Bool,
        attempt: Int = 1
    ) {
        let delay: TimeInterval = attempt == 1 ? 0.12 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard let managed = self.windowController.window(withId: windowId) else {
                Logger.debug("Minimize verification: window \(windowId) no longer tracked (reason: \(cleanupReason))")
                return
            }

            let pidDescription = "pid \(managed.backing.pid), cgWindowId \(managed.backing.cgWindowId)"
            Logger.debug(
                "Minimize verification attempt \(attempt) for window \(windowId) (\(pidDescription)), " +
                "isMinimized=\(managed.isMinimized) (reason: \(cleanupReason))"
            )

            if managed.isMinimized {
                Logger.debug("Minimize verification succeeded for window \(windowId) on attempt \(attempt)")
                self.finalizeProgrammaticMinimize(
                    windowId: windowId,
                    emptiedZoneKey: emptiedZoneKey,
                    reason: cleanupReason
                )
                return
            }

            if attempt == 1 {
                Logger.debug("Minimize verification failed for window \(windowId); retrying (reason: \(cleanupReason))")
                self.minimizeWindowProgrammatically(managed, reason: minimizeReason)
                self.scheduleMinimizeVerification(
                    windowId: windowId,
                    emptiedZoneKey: emptiedZoneKey,
                    minimizeReason: minimizeReason,
                    cleanupReason: cleanupReason,
                    wasManualResizeDetached: wasManualResizeDetached,
                    attempt: 2
                )
                return
            }

            self.rollbackFailedProgrammaticMinimize(
                managed,
                emptiedZoneKey: emptiedZoneKey,
                cleanupReason: cleanupReason,
                wasManualResizeDetached: wasManualResizeDetached
            )
        }
    }

    private func rollbackFailedProgrammaticMinimize(
        _ managed: ManagedWindow,
        emptiedZoneKey: ZoneKey?,
        cleanupReason: String,
        wasManualResizeDetached: Bool
    ) {
        guard !managed.isMinimized else {
            finalizeProgrammaticMinimize(
                windowId: managed.windowId,
                emptiedZoneKey: emptiedZoneKey,
                reason: cleanupReason
            )
            return
        }

        if wasManualResizeDetached {
            manualResizeDetachedWindowIds.insert(managed.windowId)
        }

        guard let key = emptiedZoneKey else {
            Logger.debug("Minimize rollback: window \(managed.windowId) has no prior zone (reason: \(cleanupReason))")
            return
        }

        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
        Logger.debug(
            "Minimize rollback: restoring window \(managed.windowId) to zone \(key.index) on screen \(screenIndex) (reason: \(cleanupReason))"
        )
        windowPlacementManager.placeWindow(managed, into: key, reason: "\(cleanupReason)-rollback")
    }

    // Protocol convenience overload (no duration parameter)
    internal func minimizeWindowProgrammatically(
        _ managed: ManagedWindow,
        reason: String
    ) {
        minimizeWindowProgrammatically(managed, reason: reason, suppressTimeout: 3.0)
    }

    /// Minimizes the currently active/key window using Cmd-M shortcut override
    internal func minimizeActiveWindow() {
        // Try to get the frontmost managed window
        guard let (managed, pid) = managedWindowForFrontmostApplication(
            logPrefix: "minimizeActiveWindow"
        ) else {
            Logger.debug("minimizeActiveWindow: No eligible frontmost window to minimize")
            return
        }

        let emptiedZoneKey = zoneKey(forManagedWindow: managed)

        // Get window title for logging
        var windowTitle = "untitled"
        let element = managed.backing.element
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
           let title = value as? String,
           !title.isEmpty {
            windowTitle = title
        }

        Logger.debug(
            "minimizeActiveWindow: Minimizing window \(managed.windowId) from pid \(pid) " +
            "(\(windowTitle))"
        )

        let wasManualResizeDetached = performProgrammaticMinimizeCleanup(
            managed,
            minimizeReason: "cmd-m-override",
            cleanupReason: "cmd-m-minimize",
            retarget: true
        )
        syncWindowsToZones()

        scheduleMinimizeVerification(
            windowId: managed.windowId,
            emptiedZoneKey: emptiedZoneKey,
            minimizeReason: "cmd-m-override",
            cleanupReason: "cmd-m-minimize",
            wasManualResizeDetached: wasManualResizeDetached
        )
    }

}
