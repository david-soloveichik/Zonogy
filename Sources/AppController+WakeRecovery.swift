import Foundation
import AppKit

/// Coordinates the wake recovery pipeline that rebuilds managed state after the system resumes from sleep.
extension AppController {
    final class WakeRecoveryState {
        private let attemptOffsets: [TimeInterval]
        private let startTime: Date
        private var nextAttemptIndex = 0

        var workItem: DispatchWorkItem?
        var queuedWorkspaceNotifications: [() -> Void] = []
        var isSuspended = true
        var hasCompleted = false

        init(attemptOffsets: [TimeInterval], clock: Date = Date()) {
            self.attemptOffsets = attemptOffsets
            self.startTime = clock
        }

        func nextAttemptDelay() -> (index: Int, delay: TimeInterval)? {
            guard nextAttemptIndex < attemptOffsets.count else { return nil }
            let attemptNumber = nextAttemptIndex + 1
            let targetOffset = attemptOffsets[nextAttemptIndex]
            nextAttemptIndex += 1
            let elapsed = Date().timeIntervalSince(startTime)
            let delay = max(0, targetOffset - elapsed)
            return (attemptNumber, delay)
        }

        var hasPendingAttempts: Bool {
            nextAttemptIndex < attemptOffsets.count
        }

        func cancelPendingWorkItem() {
            workItem?.cancel()
            workItem = nil
        }
    }

    internal func startWakeRecovery() {
        suspendWindowManagement(reason: "wake-recovery-start")
        guard wakeRecoveryState == nil else {
            Logger.debug("Wake recovery already active; ignoring duplicate wake notification")
            return
        }

        var managedCount = 0
        var placeholderCount = 0
        for window in windowController.allWindows {
            if window.isPlaceholder {
                placeholderCount += 1
            } else {
                managedCount += 1
            }
        }
        Logger.debug("Wake recovery starting with \(managedCount) managed windows and \(placeholderCount) placeholders")

        let attemptOffsets: [TimeInterval] = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0]
        let state = WakeRecoveryState(attemptOffsets: attemptOffsets)
        wakeRecoveryState = state

        menuBarManager.setSuspendedAppearance(true)
        pruneManagedWindowsBeforeWakeRecovery()
        removeMissingScreensForWakeRecovery()
        scheduleNextWakeRecoveryAttempt()
    }

    @discardableResult
    internal func queueWorkspaceNotificationIfSuspended(eventDescription: String, handler: @escaping () -> Void) -> Bool {
        guard let state = wakeRecoveryState, state.isSuspended else {
            return false
        }
        Logger.debug("Wake recovery: queueing \(eventDescription)")
        state.queuedWorkspaceNotifications.append(handler)
        return true
    }

    private struct WakeEnumerationOutcome {
        let windowsToMinimize: [ManagedWindow]
        let needsRetry: Bool
        let enumeratedWindowCount: Int
    }

    private func scheduleNextWakeRecoveryAttempt() {
        guard let state = wakeRecoveryState, !state.hasCompleted else { return }
        guard let (attemptIndex, delay) = state.nextAttemptDelay() else {
            Logger.debug("Wake recovery: no enumeration attempts remaining; proceeding with failure")
            let emptyOutcome = WakeEnumerationOutcome(windowsToMinimize: [], needsRetry: true, enumeratedWindowCount: 0)
            finishWakeRecovery(outcome: emptyOutcome, succeeded: false)
            return
        }

        state.cancelPendingWorkItem()
        let workItem = DispatchWorkItem { [weak self] in
            self?.executeWakeRecoveryAttempt(attemptIndex: attemptIndex)
        }
        state.workItem = workItem
        Logger.debug("Wake recovery: scheduling attempt \(attemptIndex) in \(String(format: "%.1f", delay)) second(s)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func executeWakeRecoveryAttempt(attemptIndex: Int) {
        guard let state = wakeRecoveryState, !state.hasCompleted else { return }
        state.workItem = nil

        let outcome = enumerateWindowsForWakeRecovery()
        Logger.debug(
            "Wake recovery attempt \(attemptIndex) enumerated \(outcome.enumeratedWindowCount) window(s); \(outcome.windowsToMinimize.count) candidate(s) to minimize; needsRetry=\(outcome.needsRetry)"
        )

        if outcome.needsRetry && state.hasPendingAttempts {
            scheduleNextWakeRecoveryAttempt()
            return
        }

        if outcome.needsRetry {
            Logger.debug("Wake recovery: Accessibility enumeration unavailable after attempt \(attemptIndex); proceeding with partial data")
        }

        finishWakeRecovery(outcome: outcome, succeeded: !outcome.needsRetry)
    }

    private func finishWakeRecovery(outcome: WakeEnumerationOutcome, succeeded: Bool) {
        guard let state = wakeRecoveryState else { return }
        state.hasCompleted = true
        state.cancelPendingWorkItem()
        let queuedNotifications = state.queuedWorkspaceNotifications
        state.queuedWorkspaceNotifications.removeAll()
        state.isSuspended = false
        wakeRecoveryState = nil

        if !outcome.windowsToMinimize.isEmpty {
            isWakeRecoveryMinimizing = true
            defer { isWakeRecoveryMinimizing = false }
            for window in outcome.windowsToMinimize {
                Logger.debug("Wake recovery minimizing unmanaged window \(window.windowId)")
                clearManagedWindowZone(window)
                windowController.minimizeWindow(window)
            }
        } else {
            Logger.debug("Wake recovery: no unmanaged windows required minimization")
        }

        let pendingExclusions = resumeWindowManagement(reason: "wake-recovery-complete")
        syncWindowsToZones(excluding: pendingExclusions)
        handleActiveFitActivationCandidate(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        menuBarManager.setSuspendedAppearance(false)

        Logger.debug("Wake recovery finished (success=\(succeeded)); replaying \(queuedNotifications.count) queued workspace notification(s)")
        for handler in queuedNotifications {
            handler()
        }
    }

    private func enumerateWindowsForWakeRecovery() -> WakeEnumerationOutcome {
        let visibleBundleIds = bundleIdsWithVisibleWindows()
        var needsRetry = false
        var enumeratedCount = 0
        var windowsToMinimize: [ManagedWindow] = []
        var seenWindowIds: Set<Int> = []

        for application in NSWorkspace.shared.runningApplications {
            guard shouldManage(application: application, visibleBundleIds: visibleBundleIds) else {
                continue
            }

            let result = windowController.captureWindows(
                for: application,
                notifyDelegate: false,
                allowExisting: true
            )
            enumeratedCount += result.windows.count
            if result.needsRetry {
                needsRetry = true
            }

            for window in result.windows {
                guard !window.isPlaceholder else { continue }
                guard seenWindowIds.insert(window.windowId).inserted else { continue }
                if window.zoneIndex == nil && !window.isMinimized {
                    windowsToMinimize.append(window)
                }
            }
        }

        return WakeEnumerationOutcome(
            windowsToMinimize: windowsToMinimize,
            needsRetry: needsRetry,
            enumeratedWindowCount: enumeratedCount
        )
    }

    private func pruneManagedWindowsBeforeWakeRecovery() {
        var pids: Set<pid_t> = []
        for window in windowController.allWindows {
            if case .accessibility(_, let pid, _) = window.backing {
                pids.insert(pid)
            }
        }
        guard !pids.isEmpty else {
            Logger.debug("Wake recovery: no accessibility windows to validate before enumeration")
            return
        }

        Logger.debug("Wake recovery: validating \(pids.count) pid(s) before enumeration")
        for pid in pids {
            let pruned = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "wake-recovery")
            if !pruned.isEmpty {
                Logger.debug("Wake recovery: pruned \(pruned.count) destroyed windows for pid \(pid)")
            }
        }
    }

    private func removeMissingScreensForWakeRecovery() {
        let screens = NSScreen.screens
        let result = screenContextStore.rebuild(with: screens)
        if result.removedContexts.isEmpty {
            Logger.debug("Wake recovery: no removed displays detected")
            return
        }

        let removedIds = result.removedContexts.map { $0.displayId }
        Logger.debug("Wake recovery: removing contexts for display id(s) \(removedIds)")
        handleRemovedScreens(result.removedContexts, reassignWindows: false)
    }
}
