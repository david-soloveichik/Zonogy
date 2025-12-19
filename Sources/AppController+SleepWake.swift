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
        menuBarManager.setDimmed(true)
        validationRetryManager.cancelAllValidationRetries()
        cancelWakeReadinessTimer()
        // Cancel any delayed accessibility frame retries so none fire while displays are asleep.
        windowController.cancelAllAccessibilityFrameRetries()
        // Cancel any pending window capture retries driven by AX notifications.
        capturePipeline.cancelAllRetries()
        // Cancel any pending screen-change recapture timers so they don't run during sleep.
        cancelAllPendingRecaptureWorkItems()
    }

    internal func handleScreensDidWake() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()
        Logger.debug(
            "SleepWake: screensDidWake received " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount)), " +
            "starting wake readiness polling"
        )
        startWakeReadinessPolling()
    }

    // MARK: - Core wake pipeline

    /// Polls for display, session, and AX focused-application readiness before running the wake pipeline.
    /// Matches SPECIFICATION-WAKE: wait until the primary display is awake, the session is unlocked,
    /// and AX can report an active application, polling in 0.5s increments.
    private func startWakeReadinessPolling() {
        cancelWakeReadinessTimer()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            // If we've already completed the wake pipeline (or weren't asleep), stop polling.
            if !self.screensAsleep {
                self.cancelWakeReadinessTimer()
                return
            }

            if self.isWakeEnvironmentReady() {
                Logger.debug("SleepWake: wake readiness checks passed; starting wake pipeline")
                self.cancelWakeReadinessTimer()
                self.executeSleepWakePipeline()
            } else {
                Logger.debug("SleepWake: wake readiness checks not yet satisfied; retrying in 0.5s")
            }
        }

        wakeReadinessTimer = timer
        timer.resume()
    }

    /// Cancels any in-flight wake readiness timer.
    private func cancelWakeReadinessTimer() {
        wakeReadinessTimer?.cancel()
        wakeReadinessTimer = nil
    }

    /// Returns true when the display, session, and AX focused application are ready for Accessibility work.
    /// - Display must not be asleep (CGDisplayIsAsleep == false)
    /// - Session must not be locked (CGSSessionScreenIsLocked == false)
    /// - AX must be able to return a focused application (when Accessibility permissions are granted)
    private func isWakeEnvironmentReady() -> Bool {
        let displayAwake = CGDisplayIsAsleep(primaryScreenId) == 0
        let screenLocked = isScreenLocked()

        if !displayAwake {
            Logger.debug("SleepWake: primary display is asleep; treating environment as not ready")
        }
        if screenLocked {
            Logger.debug("SleepWake: session screen is locked; treating environment as not ready")
        }

        guard displayAwake && !screenLocked else {
            return false
        }

        // If Accessibility is not trusted, do not block wake readiness on AX-focused-app checks;
        // the rest of the pipeline will still behave defensively.
        guard AXIsProcessTrusted() else {
            Logger.debug("SleepWake: Accessibility not trusted; skipping AX focused-application readiness check")
            return true
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedAppValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppValue
        )
        guard status == .success, let value = focusedAppValue else {
            Logger.debug("SleepWake: AX focused application unavailable (AX error \(status.rawValue)); treating environment as not ready")
            return false
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Logger.debug("SleepWake: AX focused element is not an application; treating environment as not ready")
            return false
        }

        return true
    }

    /// Best-effort check for whether the session screen is locked using CGSessionCopyCurrentDictionary.
    /// If the dictionary or key is unavailable, we conservatively assume the screen is unlocked to
    /// avoid stalling the wake pipeline indefinitely.
    private func isScreenLocked() -> Bool {
        guard let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            Logger.debug("SleepWake: CGSessionCopyCurrentDictionary returned nil; treating session as unlocked")
            return false
        }
        if let locked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        Logger.debug("SleepWake: CGSSessionScreenIsLocked key missing; treating session as unlocked")
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
        scheduleScreenTopologyRefresh(reason: "wake")
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
