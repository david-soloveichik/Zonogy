import Foundation
import AppKit
import ApplicationServices

/// Sleep/wake pipeline: screens-off event gating, AX readiness polling, and post-wake recapture.
extension AppController {
    // MARK: - Public entry points from SystemEventMonitor

    internal func handleScreensDidSleep() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()
        Logger.debug(
            "SleepWake: screensDidSleep received " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
        )
        screensAsleep = true
        wakeLauncherFocusRequested = false
        menuBarManager.setDimmed(true)
        cancelSleepSensitiveAsyncWork(reason: "screensDidSleep")
    }

    internal func handleScreensDidWake() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()
        Logger.debug(
            "SleepWake: screensDidWake received " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
        )
        wakeLauncherFocusRequested = false
        startWakeReadinessPolling()
    }

    // MARK: - Core wake pipeline

    /// Polls for display, session, and AX focused-application readiness before running the wake pipeline.
    /// Matches SPECIFICATION-WAKE: wait until the primary display is awake, the session is unlocked,
    /// and AX can report an active application, polling in 0.5s increments.
    private func startWakeReadinessPolling() {
        cancelWakeReadinessTimer(reason: "restarted")
        wakeReadinessPollingStartedAt = Date()
        wakeReadinessPollingAttemptCount = 0
        Logger.debug("SleepWake: wake readiness polling started (interval: 0.5s)")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            // If we've already completed the wake pipeline (or weren't asleep), stop polling.
            if !self.screensAsleep {
                self.cancelWakeReadinessTimer(reason: "cancelled (screens already awake)")
                return
            }

            self.wakeReadinessPollingAttemptCount += 1
            if self.isWakeEnvironmentReady() {
                self.cancelWakeReadinessTimer(reason: "completed (environment ready)")
                self.executeSleepWakePipeline()
            }
        }

        wakeReadinessTimer = timer
        timer.resume()
    }

    /// Cancels any in-flight wake readiness timer and logs a concise polling summary when applicable.
    private func cancelWakeReadinessTimer(reason: String? = nil) {
        guard wakeReadinessTimer != nil else {
            return
        }
        wakeReadinessTimer?.cancel()
        wakeReadinessTimer = nil

        let attempts = wakeReadinessPollingAttemptCount
        wakeReadinessPollingAttemptCount = 0

        guard let startedAt = wakeReadinessPollingStartedAt else {
            return
        }
        wakeReadinessPollingStartedAt = nil

        let duration = Date().timeIntervalSince(startedAt)
        let durationString = String(format: "%.1f", duration)
        if let reason {
            Logger.debug(
                "SleepWake: wake readiness polling ended " +
                "(attempts: \(attempts), duration: \(durationString)s, reason: \(reason))"
            )
        } else {
            Logger.debug(
                "SleepWake: wake readiness polling ended " +
                "(attempts: \(attempts), duration: \(durationString)s)"
            )
        }
    }

    /// Returns true when the display, session, and frontmost application are ready for Accessibility work.
    /// - Display must not be asleep (CGDisplayIsAsleep == false)
    /// - Session must not be locked (CGSSessionScreenIsLocked == false)
    /// - NSWorkspace must be able to return a frontmost application
    private func isWakeEnvironmentReady() -> Bool {
        let displayAwake = CGDisplayIsAsleep(primaryScreenId) == 0
        let screenLocked = isScreenLocked()

        if displayAwake && !screenLocked,
           launcherController.isActive,
           !wakeLauncherFocusRequested {
            wakeLauncherFocusRequested = true
            launcherController.makeKeyIfActive()
        }

        guard displayAwake && !screenLocked else {
            return false
        }

        // Use NSWorkspace to check for frontmost application instead of AX API,
        // which can hang indefinitely with some apps (e.g., VS Code/Electron).
        guard NSWorkspace.shared.frontmostApplication != nil else { return false }

        return true
    }

    /// Best-effort check for whether the session screen is locked using CGSessionCopyCurrentDictionary.
    /// If the dictionary or key is unavailable, we conservatively assume the screen is unlocked to
    /// avoid stalling the wake pipeline indefinitely.
    private func isScreenLocked() -> Bool {
        guard let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        return false
    }

    // MARK: - Wake pipeline implementation

    private func executeSleepWakePipeline() {
        Logger.debug("SleepWake: wake readiness satisfied; scheduling screen-topology refresh and recapture")

        // Mark screens as awake so external events are processed again.
        screensAsleep = false
        menuBarManager.setDimmed(false)

        // Reuse the same code path that handles display changes:
        // this rebuilds screen topology, minimizes windows on removed displays,
        // syncs windows to zones, and schedules recapture passes.
        scheduleScreenTopologyRefresh(reason: "wake", includesWake: true)
    }

    // MARK: - Sleep-sensitive async work cancellation

    /// Central cancellation funnel for timers/work items that must not run while screens are asleep.
    /// Any new delayed AX/window-state work should be cancelled from this path.
    internal func cancelSleepSensitiveAsyncWork(reason: String) {
        validationRetryManager.cancelAllValidationRetries()
        cancelUnmanagedFocusRetry()
        cancelWakeReadinessTimer(reason: "cancelled (\(reason))")
        cancelWakeAXWindowPollingTimer(reason: reason)

        // AX/state pipelines that should not execute during sleep.
        windowController.cancelAllAccessibilityFrameRetries(reason: "sleep-sensitive-cancel-\(reason)")
        capturePipeline.cancelAllRetries()
        deferredMinimizationCoordinator.cancelAll(reason: reason)
        cancelAllPendingRecaptureWorkItems()
        cancelPendingScreenTopologyRefreshWork()
        cancelPendingFullScreenAsyncChecks()
        cancelTemporaryZoneProtectionAsyncWork()
        cancelPendingWindowActivityRecord()

        // Clear suppression windows since they are no longer meaningful across sleep transitions.
        activityRecordingSuppressedUntil = nil
    }

    private func cancelWakeAXWindowPollingTimer(reason: String) {
        guard let timer = wakeAXWindowPollingTimer else {
            return
        }
        timer.cancel()
        wakeAXWindowPollingTimer = nil
        Logger.debug("SleepWake: cancelled AX window polling timer (reason: \(reason))")
    }

    private func cancelPendingScreenTopologyRefreshWork() {
        pendingScreenChangeWorkItem?.cancel()
        pendingScreenChangeWorkItem = nil
        pendingScreenChangeReason = nil
        pendingScreenChangeIncludesWake = false
        pendingScreenChangeDisplayIds.removeAll()
    }

    private func cancelPendingFullScreenAsyncChecks() {
        for workItem in fullScreenCheckWorkItemsByWindowId.values {
            workItem.cancel()
        }
        fullScreenCheckWorkItemsByWindowId.removeAll()

        for workItem in fullScreenCheckWorkItemsByElement.values {
            workItem.cancel()
        }
        fullScreenCheckWorkItemsByElement.removeAll()

        pendingFullScreenSpaceChangeWorkItem?.cancel()
        pendingFullScreenSpaceChangeWorkItem = nil
    }

    private func cancelTemporaryZoneProtectionAsyncWork() {
        for workItem in temporaryZoneProtectionExpirationWorkItems.values {
            workItem.cancel()
        }
        temporaryZoneProtectionExpirationWorkItems.removeAll()
        temporaryZoneProtectionDeadlines.removeAll()
    }

    // MARK: - Event gating helper

    /// Returns true when events should be ignored due to screens being asleep.
    /// Call this at the top of delegate handlers that respond to external notifications.
    internal func shouldIgnoreDueToSleepWake(event: String) -> Bool {
        guard screensAsleep else {
            return false
        }
        Logger.debug("SleepWake: ignoring \(event) because screens are asleep")
        return true
    }
}
