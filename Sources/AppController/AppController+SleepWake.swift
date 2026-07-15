import Foundation
import AppKit
import ApplicationServices
import OSLog

/// Sleep/wake pipeline: screens-off event gating, AX readiness polling, and post-wake recapture.
extension AppController {
    private static let loginWindowBundleIdentifier = "com.apple.loginwindow"

    // MARK: - Public entry points from SystemEventMonitor

    internal func handleScreensDidSleep() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()
        Logger.debug(
            "SleepWake: screensDidSleep received " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
        )
        enterSleepWakeProtection(reason: "screensDidSleep")
    }

    internal func handleLoginWindowDidActivate(reason: String) {
        let wasActive = loginWindowIsActive
        loginWindowIsActive = true

        guard !sleepWakeProtectionActive else {
            if !wasActive {
                Logger.debug("SleepWake: loginwindow became active while protection was already enabled (reason: \(reason))")
            }
            return
        }

        let (managedWindowCount, placeholderCount) = currentWindowCounts()
        Logger.debug(
            "SleepWake: loginwindow became active; entering protection " +
            "(reason: \(reason), managed: \(managedWindowCount), placeholders: \(placeholderCount))"
        )
        enterSleepWakeProtection(reason: "loginwindow-active")
    }

    internal func handleLoginWindowDidDeactivate(reason: String) {
        guard loginWindowIsActive else {
            return
        }

        loginWindowIsActive = false
        Logger.debug("SleepWake: loginwindow no longer active; starting wake readiness polling (reason: \(reason))")
        wakeLauncherFocusRequested = false
        if sleepWakeProtectionActive {
            startWakeReadinessPolling(reason: "loginwindow-inactive")
        }
    }

    @discardableResult
    internal func enterLoginWindowProtectionIfFrontmost(reason: String) -> Bool {
        guard isLoginWindowApplication(NSWorkspace.shared.frontmostApplication) else {
            return false
        }
        handleLoginWindowDidActivate(reason: reason)
        return true
    }

    internal func isLoginWindowApplication(_ application: NSRunningApplication?) -> Bool {
        application?.bundleIdentifier == Self.loginWindowBundleIdentifier
    }

    internal func handleScreensDidWake() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()
        Logger.debug(
            "SleepWake: screensDidWake received " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
        )
        wakeLauncherFocusRequested = false
        startWakeReadinessPolling(reason: "screensDidWake")
    }

    private func enterSleepWakeProtection(reason: String) {
        sleepWakeProtectionActive = true
        wakeLauncherFocusRequested = false
        menuBarManager.setDimmed(true)
        windowFocusNavigationInterceptor.resetEngagement()
        cancelWindowFocusNavigation(reason: reason)
        cancelSleepSensitiveAsyncWork(reason: reason)
    }

    // MARK: - Core wake pipeline

    /// Polls for display, session, and frontmost-application readiness before running the wake pipeline.
    /// Matches SPECIFICATION-WAKE: wait until the primary display is awake, the session is unlocked,
    /// and NSWorkspace reports a non-loginwindow application, polling in 0.5s increments.
    private func startWakeReadinessPolling(reason: String) {
        cancelWakeReadinessTimer(reason: "restarted")
        wakeReadinessPollingStartedAt = Date()
        wakeReadinessPollingAttemptCount = 0
        Logger.debug("SleepWake: wake readiness polling started (reason: \(reason), interval: 0.5s, leeway: 0.25s)")
        ZonogySignposts.pointsOfInterest.emitEvent("WakeReadinessPollingStart")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(500),
            repeating: .milliseconds(500),
            leeway: .milliseconds(250)
        )

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            // If we've already completed the wake pipeline (or weren't asleep), stop polling.
            if !self.sleepWakeProtectionActive {
                self.cancelWakeReadinessTimer(reason: "cancelled (sleep/wake protection already inactive)")
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
            ZonogySignposts.pointsOfInterest.emitEvent(
                "WakeReadinessPollingEnd",
                "attempts=\(attempts) duration=\(durationString, privacy: .public) reason=\(reason, privacy: .public)"
            )
            Logger.debug(
                "SleepWake: wake readiness polling ended " +
                "(attempts: \(attempts), duration: \(durationString)s, reason: \(reason))"
            )
        } else {
            ZonogySignposts.pointsOfInterest.emitEvent(
                "WakeReadinessPollingEnd",
                "attempts=\(attempts) duration=\(durationString, privacy: .public)"
            )
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

        guard displayAwake && !screenLocked else {
            return false
        }

        // Use NSWorkspace to check for frontmost application instead of AX API,
        // which can hang indefinitely with some apps (e.g., VS Code/Electron).
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              !isLoginWindowApplication(frontmostApplication) else {
            return false
        }

        if launcherController.isActive, !wakeLauncherFocusRequested {
            wakeLauncherFocusRequested = true
            launcherController.makeKeyIfActive()
        }

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
        sleepWakeProtectionActive = false
        loginWindowIsActive = false
        menuBarManager.setDimmed(false)

        // Reuse the same code path that handles display changes:
        // this rebuilds screen topology, minimizes windows on removed displays,
        // syncs windows to zones, and schedules recapture passes.
        scheduleScreenTopologyRefresh(reason: "wake", includesWake: true)
    }

    // MARK: - Sleep-sensitive async work cancellation

    /// Central cancellation funnel for timers/work items that must not run during sleep/wake protection.
    /// Any new delayed AX/window-state work should be cancelled from this path.
    internal func cancelSleepSensitiveAsyncWork(reason: String) {
        validationRetryManager.cancelAllValidationRetries()
        cancelUnmanagedFocusRetry()
        cancelUnmanagedWindowEdgeDrag(reason: reason)
        cancelWakeReadinessTimer(reason: "cancelled (\(reason))")
        cancelWakeAXWindowPollingTimer(reason: reason)

        // AX/state pipelines that should not execute during sleep.
        windowController.cancelAllAccessibilityFrameRetries(reason: "sleep-sensitive-cancel-\(reason)")
        capturePipeline.cancelAllRetries()
        deferredMinimizationCoordinator.cancelAll(reason: reason)
        cancelAllPendingRecaptureWorkItems()
        cancelPendingScreenTopologyRefreshWork()
        cancelPendingFullScreenAsyncChecks()
        cancelFloatingZoneProtectionAsyncWork()
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

    private func cancelFloatingZoneProtectionAsyncWork() {
        for workItem in floatingZoneProtectionExpirationWorkItems.values {
            workItem.cancel()
        }
        floatingZoneProtectionExpirationWorkItems.removeAll()
        floatingZoneProtectionDeadlines.removeAll()
    }

    // MARK: - Event gating helper

    /// Returns true when events should be ignored due to screens being asleep.
    /// Call this at the top of delegate handlers that respond to external notifications.
    internal func shouldIgnoreDueToSleepWake(event: String) -> Bool {
        guard sleepWakeProtectionActive else {
            return false
        }
        Logger.debug("SleepWake: ignoring \(event) because sleep/wake protection is active")
        return true
    }
}
