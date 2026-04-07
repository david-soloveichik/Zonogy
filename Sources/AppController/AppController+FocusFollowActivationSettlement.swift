import AppKit
import Foundation

/// Follows-focus activation settlement that preserves the current target while app activation churn settles.
extension AppController {
    internal func beginFocusFollowActivationSettlementIfNeeded(
        pid: pid_t,
        bundleIdentifier: String?,
        focusedWindowId: Int
    ) {
        guard let managed = windowController.window(withId: focusedWindowId),
              let focusedDestination = followsFocusDestination(for: managed),
              FocusFollowActivationSettlementPolicy.shouldDeferImmediateRetarget(
                targetingMode: targetingMode,
                currentTarget: targetedZoneManager.targetedDestination,
                focusedDestination: focusedDestination,
                isMostRecentlyActive: windowController.isMostRecentlyActive(windowId: focusedWindowId)
              ) else {
            cancelFocusFollowActivationSettlement(pid: pid, reason: "activation-no-deferral-needed")
            return
        }

        cancelFocusFollowActivationSettlement(pid: pid, reason: "activation-restarted")
        cancelPendingWindowActivityRecord()

        focusFollowActivationSettlements[pid] = FocusFollowActivationSettlement(
            bundleIdentifier: bundleIdentifier,
            initialTarget: targetedZoneManager.targetedDestination,
            initialFocusedWindowId: focusedWindowId,
            hasLoggedSuppression: false
        )

        Logger.debug(
            "Focus-follow activation settlement started for pid \(pid) " +
            "(bundle: \(bundleIdentifier ?? "unknown"), focusedWindow: \(focusedWindowId), " +
            "preserving target: \(focusFollowTargetLogDescription(targetedZoneManager.targetedDestination)))"
        )

        scheduleFocusFollowActivationSettlementTimeout(pid: pid)
    }

    internal func shouldSuppressFollowsFocusRetargetDuringActivation(pid: pid_t, reason: String) -> Bool {
        guard var settlement = focusFollowActivationSettlements[pid] else {
            return false
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            cancelFocusFollowActivationSettlement(pid: pid, reason: "activation-no-longer-frontmost")
            return false
        }

        if !settlement.hasLoggedSuppression {
            settlement.hasLoggedSuppression = true
            focusFollowActivationSettlements[pid] = settlement
            Logger.debug(
                "Suppressing follows-focus retarget for pid \(pid) during activation settlement " +
                "(reason: \(reason), preserving target: \(focusFollowTargetLogDescription(settlement.initialTarget)))"
            )
        }

        return true
    }

    internal func cancelFocusFollowActivationSettlementForCapturedWindowIfNeeded(_ window: ManagedWindow) {
        guard focusFollowActivationSettlements[window.backing.pid] != nil else {
            return
        }
        cancelFocusFollowActivationSettlement(
            pid: window.backing.pid,
            reason: "captured-window-\(window.windowId)"
        )
    }

    internal func cancelFocusFollowActivationSettlement(pid: pid_t, reason: String) {
        let removedSettlement = focusFollowActivationSettlements.removeValue(forKey: pid)
        let removedWorkItem = focusFollowActivationSettlementWorkItems.removeValue(forKey: pid)
        removedWorkItem?.cancel()

        guard removedSettlement != nil || removedWorkItem != nil else {
            return
        }

        Logger.debug("Focus-follow activation settlement cleared for pid \(pid) (reason: \(reason))")
    }

    private func scheduleFocusFollowActivationSettlementTimeout(pid: pid_t) {
        focusFollowActivationSettlementWorkItems[pid]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.completeFocusFollowActivationSettlement(pid: pid)
        }

        focusFollowActivationSettlementWorkItems[pid] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + focusFollowActivationSettlementDuration,
            execute: workItem
        )
    }

    private func completeFocusFollowActivationSettlement(pid: pid_t) {
        focusFollowActivationSettlementWorkItems.removeValue(forKey: pid)

        guard let settlement = focusFollowActivationSettlements.removeValue(forKey: pid) else {
            return
        }

        guard targetingMode == .followsFocus else {
            Logger.debug("Focus-follow activation settlement expired for pid \(pid), but follows-focus mode is disabled")
            return
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            Logger.debug("Focus-follow activation settlement expired for pid \(pid), but the app is no longer frontmost")
            return
        }

        guard FocusFollowActivationSettlementPolicy.shouldApplySettledRetarget(
            currentTarget: targetedZoneManager.targetedDestination,
            initialTarget: settlement.initialTarget
        ) else {
            Logger.debug(
                "Focus-follow activation settlement expired for pid \(pid), but target changed from " +
                "\(focusFollowTargetLogDescription(settlement.initialTarget)) to " +
                "\(focusFollowTargetLogDescription(targetedZoneManager.targetedDestination)); skipping settled retarget"
            )
            return
        }

        guard let focused = windowController.focusedWindowIfTracked(pid: pid) else {
            Logger.debug("Focus-follow activation settlement expired for pid \(pid), but no tracked focused window is available")
            return
        }

        Logger.debug(
            "Focus-follow activation settlement expired for pid \(pid); retargeting to focused window \(focused.windowId)"
        )
        recordActiveWindowForHistory(windowId: focused.windowId, reason: "workspace-activate-settled")
    }

    private func followsFocusDestination(for managed: ManagedWindow) -> TargetedZoneManager.TargetedDestination? {
        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId ?? detectScreenId(for: managed) {
            return .tiled(ZoneKey(screenId: screenId, index: zoneIndex))
        }

        guard isWindowInFloatingZone(managed.windowId) else {
            return nil
        }

        guard let screenId = managed.screenDisplayId
            ?? floatingZoneCoordinator.occupants.first(where: { $0.value == managed.windowId })?.key
            ?? detectScreenId(for: managed) else {
            return nil
        }

        return .floating(screenId: screenId)
    }

    private func focusFollowTargetLogDescription(
        _ destination: TargetedZoneManager.TargetedDestination?
    ) -> String {
        guard let destination else {
            return "none"
        }

        switch destination {
        case .tiled(let key):
            return "screen \(screenContextStore.loggingIndex(for: key.screenId)) zone \(key.index)"
        case .floating(let screenId):
            return "floating on screen \(screenContextStore.loggingIndex(for: screenId))"
        }
    }
}
