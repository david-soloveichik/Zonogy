import Foundation
import AppKit
import ApplicationServices

/// Deferred-prune bookkeeping and live-tracking teardown for managed windows.
extension WindowController {
    @discardableResult
    internal func restorePendingPrunedWindowIfNeeded(
        identifier: ExternalWindowIdentifier,
        element: AXUIElement,
        appElement: AXUIElement,
        notifyDelegate: Bool,
        isMinimized: Bool
    ) -> ManagedWindow? {
        guard let pending = pendingPrunedWindows.restoreMatch(for: identifier) else {
            return nil
        }

        let managed = ManagedWindow(
            windowId: pending.windowId,
            backing: ManagedWindowBacking(element: element, pid: identifier.pid, cgWindowId: identifier.cgWindowId)
        )
        windowRegistry.insert(managed)
        externalWindowsByElement[AccessibilityElementKey(element: element)] = managed
        externalWindows[identifier] = managed

        if let lastActiveTime = pending.lastActiveTime {
            windowLastActiveTime[managed.windowId] = lastActiveTime
            restoredPendingPruneActivitySkipWindowIds.insert(managed.windowId)
        } else {
            windowLastActiveTime.removeValue(forKey: managed.windowId)
        }
        restoredPendingPruneDestinationsByWindowId[managed.windowId] = pending.preferredDestination

        registerAccessibilityNotifications(for: managed, appElement: appElement)

        if isMinimized {
            Logger.debug("Restored deferred-prune window \(identifier.cgWindowId) from pid \(identifier.pid) as managed id \(managed.windowId) (tracking only, no zone placement)")
        } else {
            Logger.debug("Restored deferred-prune window \(identifier.cgWindowId) from pid \(identifier.pid) as managed id \(managed.windowId)")
        }

        if notifyDelegate && !isMinimized {
            delegate?.windowController(self, didCaptureExternalWindow: managed)
        }

        return managed
    }

    internal func clearPendingPrunedWindowsForNewManagedWindow(
        pid: pid_t,
        discoveredIdentifier: ExternalWindowIdentifier
    ) {
        let cleared = pendingPrunedWindows.clear(forPid: pid)
        guard !cleared.isEmpty else {
            return
        }

        for entry in cleared {
            restoredPendingPruneActivitySkipWindowIds.remove(entry.windowId)
        }

        let reason = "new-managed-cgwindowid-\(discoveredIdentifier.cgWindowId)"
        Logger.debug(
            "Discarded \(cleared.count) deferred-prune window(s) for pid \(pid) after discovering new managed CGWindowID \(discoveredIdentifier.cgWindowId)"
        )
        delegate?.windowController(self, didDiscardPendingPrunedWindowIds: cleared.map { $0.windowId }, reason: reason)
    }

    internal func discardPendingPrunedWindows(forPid pid: pid_t, reason: String) {
        let cleared = pendingPrunedWindows.clear(forPid: pid)
        guard !cleared.isEmpty else {
            return
        }

        for entry in cleared {
            restoredPendingPruneActivitySkipWindowIds.remove(entry.windowId)
        }

        Logger.debug("Discarded \(cleared.count) deferred-prune window(s) for pid \(pid) (reason: \(reason))")
        delegate?.windowController(self, didDiscardPendingPrunedWindowIds: cleared.map { $0.windowId }, reason: reason)
    }

    internal func hasPendingPrunedEntry(forWindowId windowId: Int) -> Bool {
        pendingPrunedWindows.hasEntry(forWindowId: windowId)
    }

    internal func consumeRestoredPendingPruneDestination(for windowId: Int) -> PendingPrunedWindowDestination? {
        restoredPendingPruneDestinationsByWindowId.removeValue(forKey: windowId)
    }

    internal func stagePendingPrunedWindow(
        _ managed: ManagedWindow,
        reason: String
    ) {
        let windowId = managed.windowId
        let identifier = managed.externalIdentifier
        let lastActiveTime = windowLastActiveTime.removeValue(forKey: windowId)
        let preferredDestination = pendingPrunedWindowDestination(for: managed)

        pendingPrunedWindows.stage(
            identifier: identifier,
            windowId: windowId,
            lastActiveTime: lastActiveTime,
            preferredDestination: preferredDestination
        )
        removeManagedWindowFromLiveTracking(managed)

        Logger.debug(
            "Staged window \(windowId) for deferred prune (pid \(identifier.pid), CGWindowID \(identifier.cgWindowId), reason: \(reason))"
        )
    }

    internal func removeManagedWindowFromLiveTracking(_ managed: ManagedWindow) {
        let windowId = managed.windowId
        removeAccessibilityTracking(for: managed)
        externalWindows.removeValue(forKey: managed.externalIdentifier)
        windowRegistry.removeWindow(withId: windowId)

        clearBackingScopedState(for: windowId, reason: "remove-live-tracking")
        restoredPendingPruneActivitySkipWindowIds.remove(windowId)
        restoredPendingPruneDestinationsByWindowId.removeValue(forKey: windowId)

        if currentDraggingWindowId == windowId {
            currentDraggingWindowId = nil
        }
        if dragCandidate?.windowId == windowId {
            dragCandidate = nil
        }

        updateMouseUpGlobalMonitorInstallation()
    }

    internal func clearBackingScopedState(for windowId: Int, reason: String) {
        lastConfirmedAliveAt.removeValue(forKey: windowId)
        programmaticUpdateWindowIds.remove(windowId)
        programmaticUpdateWorkItems[windowId]?.cancel()
        programmaticUpdateWorkItems.removeValue(forKey: windowId)

        if var retryState = accessibilityFrameRetryStates.removeValue(forKey: windowId) {
            retryState.cancel()
            Logger.debug("Cancelled frame retry chain for window \(windowId) (reason: \(reason))")
        }
    }

    private func pendingPrunedWindowDestination(for managed: ManagedWindow) -> PendingPrunedWindowDestination? {
        if managed.isInFloatingZone, let screenId = managed.screenDisplayId {
            return .floating(screenId)
        }
        if let screenId = managed.screenDisplayId, let zoneIndex = managed.zoneIndex {
            return .tiled(ZoneKey(screenId: screenId, index: zoneIndex))
        }
        return nil
    }
}
