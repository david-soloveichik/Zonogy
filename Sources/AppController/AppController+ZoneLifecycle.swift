import Foundation
import AppKit
import ApplicationServices

/// Zone lifecycle: window commands, resize handle delegation, event suppression, and programmatic minimize.
extension AppController {

    // MARK: - Window Management

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

    internal func beginZoneResizeDrag(screenId: CGDirectDisplayID, separatorId: ZoneLayout.SeparatorIdentity) {
        Logger.debug("Zone resize drag began on \(screenContextStore.logDescription(for: screenId)) separator \(separatorId.logLabel)")
        zoneResizeDragScreenId = screenId
        liveResizePreviousFrames.removeAll()
        activeFitZoneResizeLoggedWindowIds.removeAll()
        // Return any window in reveal mode to rest mode before live resizing.
        exitRevealMode(reason: "zone-resize-begin")
    }

    internal func endZoneResizeDrag(screenId: CGDirectDisplayID, separatorId: ZoneLayout.SeparatorIdentity) {
        Logger.debug("Zone resize drag ended on \(screenContextStore.logDescription(for: screenId)) separator \(separatorId.logLabel)")
        zoneResizeDragScreenId = nil
        liveResizePreviousFrames.removeAll()
        activeFitZoneResizeLoggedWindowIds.removeAll()

        // When resizing stops, if the active window qualifies, re-evaluate ActiveFit.
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        handleActiveFitActivationCandidate(pid: pid)

        // Refresh resize handles after the drag so overlap rules (ActiveFit and
        // frontmost-zone-1 suppression) take effect for the settled state.
        DispatchQueue.main.async { [weak self] in
            self?.refreshResizeHandles()
        }
    }

    func resizeHandleDragBegan(screenId: CGDirectDisplayID, separatorId: ZoneLayout.SeparatorIdentity) {
        beginZoneResizeDrag(screenId: screenId, separatorId: separatorId)
    }

    func resizeHandleDragged(screenId: CGDirectDisplayID, separatorId: ZoneLayout.SeparatorIdentity, delta: CGPoint) {
        guard let context = screenContexts[screenId] else { return }

        guard context.zoneController.separators().contains(where: { $0.id == separatorId }) else { return }

        let scalarDelta: CGFloat
        switch separatorId.orientation {
        case .vertical:
            scalarDelta = delta.x
        case .horizontal:
            scalarDelta = delta.y
        }

        guard abs(scalarDelta) > 0.001 else { return }

        clearRememberedManualResizeSizes(on: screenId, reason: "zone-resize-drag")

        // Apply resize
        context.zoneController.resizeBySeparator(id: separatorId, delta: scalarDelta)

        // Live separator drags only change zone geometry; use the fast sync path
        // and defer full reconciliation/indicator refresh until mouse-up.
        syncWindowsToZonesForLiveResize(screenId: screenId)
    }

    func isResizeHandleSyncBusy() -> Bool {
        windowController.isLiveResizeAXQueueBusy
    }

    func resizeHandleDragEnded(screenId: CGDirectDisplayID, separatorId: ZoneLayout.SeparatorIdentity) {
        endZoneResizeDrag(screenId: screenId, separatorId: separatorId)
        // Drain any in-flight async AX writes before the full sync, so stale
        // background writes cannot overwrite the corrected final frames.
        windowController.drainLiveResizeQueue()
        syncWindowsToZones()
        // Tiling windows may now occlude the floating-zone window after the resize.
        queueOcclusionBasedFloatingZoneMinimizationIfNeeded(on: screenId, reason: "zone-resize-end")
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
        // Loop guard: when an external app is fighting our minimizes by re-unminimizing
        // them rapidly, route through the deferred queue so the app's queue can drain
        // first. This is a safety net for placement paths that requested `.synchronous`
        // displacement; `placeNewWindow` already uses `.deferred` directly.
        if minimizeLoopGuard.isLoopActive {
            Logger.debug(
                "Loop guard active: redirecting programmatic minimize to deferred queue for window \(managed.windowId) (reason: \(reason))"
            )
            queueDeferredMinimization(windowId: managed.windowId, reason: "loop-guard-\(reason)")
            return
        }

        suppressNextEvents(for: [managed.windowId], events: [.miniaturized], timeout: suppressTimeout, reason: reason)
        minimizeLoopGuard.recordProgrammaticMinimize(windowId: managed.windowId)
        windowController.minimizeWindow(managed)
    }

    internal func bulkProgrammaticMinimize(
        _ windows: [ManagedWindow],
        minimizeReason: String,
        cleanupReason: String,
        assignmentCleanup: (ManagedWindow) -> Void
    ) {
        var uniqueWindows: [ManagedWindow] = []
        var seenWindowIds: Set<Int> = []
        for managed in windows where seenWindowIds.insert(managed.windowId).inserted {
            uniqueWindows.append(managed)
        }

        guard !uniqueWindows.isEmpty else {
            return
        }

        let manualResizeStates = Dictionary(
            uniqueKeysWithValues: uniqueWindows.map { managed in
                (
                    managed.windowId,
                    ManualResizeCleanupState(
                        wasDetached: manualResizeDetachedWindowIds.contains(managed.windowId),
                        rememberedSize: rememberedManualResizeSizesByWindowId[managed.windowId]
                    )
                )
            }
        )

        let windowIds = uniqueWindows.map(\.windowId)
        suppressNextEvents(for: windowIds, events: [.miniaturized], reason: minimizeReason)

        for managed in uniqueWindows {
            windowController.minimizeWindow(managed)
        }

        for managed in uniqueWindows {
            assignmentCleanup(managed)
        }

        for managed in uniqueWindows {
            scheduleMinimizeVerification(
                windowId: managed.windowId,
                emptiedZoneKey: nil,
                minimizeReason: minimizeReason,
                cleanupReason: cleanupReason,
                manualResizeState: manualResizeStates[managed.windowId]
                    ?? ManualResizeCleanupState(wasDetached: false, rememberedSize: nil)
            )
        }
    }

    @discardableResult
    internal func performProgrammaticMinimizeCleanup(
        _ managed: ManagedWindow,
        minimizeReason: String,
        cleanupReason: String,
        retarget: Bool = true
    ) -> ManualResizeCleanupState {
        let cleanupState = ManualResizeCleanupState(
            wasDetached: manualResizeDetachedWindowIds.contains(managed.windowId),
            rememberedSize: rememberedManualResizeSizesByWindowId[managed.windowId]
        )
        minimizeWindowProgrammatically(managed, reason: minimizeReason)
        removeWindowFromAllZones(windowId: managed.windowId, reason: cleanupReason, retarget: retarget)
        return cleanupState
    }

    internal func finalizeProgrammaticMinimize(
        windowId: Int,
        emptiedZoneKey: ZoneKey?,
        reason: String
    ) {
        // Note: emptiedZoneKey is no longer used - floating zone promotion is now
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
        manualResizeState: ManualResizeCleanupState,
        attempt: Int = 1
    ) {
        let delay: TimeInterval = attempt == 1 ? 0.12 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard !self.sleepWakeProtectionActive else {
                Logger.debug("Minimize verification skipped for window \(windowId) because sleep/wake protection is active (reason: \(cleanupReason))")
                return
            }
            guard let managed = self.windowController.window(withId: windowId) else {
                Logger.debug("Minimize verification: window \(windowId) no longer tracked (reason: \(cleanupReason))")
                return
            }

            let pidDescription = "pid \(managed.backing.pid), cgWindowId \(managed.backing.cgWindowId)"
            Logger.debug(
                "Minimize verification attempt \(attempt) for window \(windowId) (\(pidDescription)), " +
                "isMinimized=\(managed.isMinimizedPerAccessibility) (reason: \(cleanupReason))"
            )

            if managed.isMinimizedPerAccessibility {
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
                    manualResizeState: manualResizeState,
                    attempt: 2
                )
                return
            }

            self.rollbackFailedProgrammaticMinimize(
                managed,
                emptiedZoneKey: emptiedZoneKey,
                cleanupReason: cleanupReason,
                manualResizeState: manualResizeState
            )
        }
    }

    private func rollbackFailedProgrammaticMinimize(
        _ managed: ManagedWindow,
        emptiedZoneKey: ZoneKey?,
        cleanupReason: String,
        manualResizeState: ManualResizeCleanupState
    ) {
        guard !managed.isMinimizedPerAccessibility else {
            finalizeProgrammaticMinimize(
                windowId: managed.windowId,
                emptiedZoneKey: emptiedZoneKey,
                reason: cleanupReason
            )
            return
        }

        if let rememberedSize = manualResizeState.rememberedSize {
            rememberedManualResizeSizesByWindowId[managed.windowId] = rememberedSize
        }

        if manualResizeState.wasDetached {
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

    /// Minimizes the currently active/key window using Cmd-M shortcut override.
    /// Before issuing the AX minimize call, we optimistically retarget to the window's zone
    /// and show the Launcher (when enabled) so the user sees immediate feedback. Zone
    /// bookkeeping stays intact: the AXWindowMiniaturized notification handler
    /// (windowDidMiniaturize) runs the full pipeline.
    internal func minimizeActiveWindow() {
        guard let (managed, pid) = managedWindowForFrontmostApplication(
            logPrefix: "minimizeActiveWindow"
        ) else {
            Logger.debug("minimizeActiveWindow: No eligible frontmost window to minimize")
            return
        }

        Logger.debug(
            "minimizeActiveWindow: Minimizing window \(managed.windowId) from pid \(pid)"
        )

        optimisticallyShowLauncherForMinimize(managed, reason: "cmd-m-optimistic")
        windowController.minimizeWindow(managed)
    }

}
