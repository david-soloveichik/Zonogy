import Foundation
import AppKit

/// Handles application launch, quit, and state-change events and applications that answer
/// Accessibility requests again, and schedules capture.
extension AppController {
    @objc internal func handleAccessibilityApplicationAnswered(_ notification: Notification) {
        guard let pid = notification.userInfo?["pid"] as? pid_t, !sleepWakeProtectionActive else {
            return
        }
        // While its requests failed at once, the application's windows may have changed unseen:
        // re-read the full-screen state of those that show or are recorded as full screen (the
        // application may still be slow, so the rest are spared the reads), capture what is new,
        // and sync the zones.
        for window in windowController.allWindows
        where window.backing.pid == pid
            && (isTrackedFullScreenWindow(window)
                || WindowServerWindowList.frame(for: window.backing.cgWindowId, ownerPid: pid) != nil) {
            checkWindowFullScreenState(windowId: window.windowId)
        }
        capturePipeline.retryAfterAnswer(forPid: pid)
        showLaunchedWindowIfOnlyMinimized(pid: pid)
        syncWindowsToZones()
    }

    internal func handleApplicationEvent(_ application: NSRunningApplication?) {
        guard let application else {
            Logger.debug("handleApplicationEvent: application is nil, skipping")
            return
        }

        let appDescription = "\(application.localizedName ?? "Unknown") (pid \(application.processIdentifier), bundle \(application.bundleIdentifier ?? "nil"))"

        guard shouldManage(application: application, logRejection: true) else {
            return
        }

        Logger.debug("handleApplicationEvent: scheduling capture for \(appDescription)")
        scheduleCapture(for: application, delay: 0.0)
        scheduleCapture(for: application, delay: 0.4)
    }

    internal func handleApplicationStateChange(_ application: NSRunningApplication?) {
        guard let application else {
            return
        }

        guard shouldManage(application: application) else {
            return
        }

        // When an application changes state (deactivate/hide), validate all its windows
        // This catches window closures that didn't fire destroy notifications
        _ = validationRetryManager.validateWindowsForApplication(pid: application.processIdentifier, trigger: .workspaceStateChange)
    }

    internal func handleApplicationTermination(_ application: TerminatedApplication) {
        let pid = application.pid
        var details = "\(application.localizedName ?? "Unknown App"), pid \(pid)"
        if let bundleId = application.bundleIdentifier {
            details += ", bundle \(bundleId)"
        }
        Logger.debug("Application terminated: \(details)")

        // Notify full-screen tracker that this app terminated
        notifyFullScreenTrackerOfAppTermination(pid: pid)
        clearUnmanagedWindowEdgeState(forPid: pid, reason: "application-termination")

        capturePipeline.cancelRetry(forPid: pid)
        // A terminated app's windows vanish with it: retire any pass-through holes they
        // earned, even when the app had no managed windows (no sync runs then).
        schedulePlaceholderPassThroughRefresh(reason: "application-termination")
        // When an application terminates, remove all of its managed windows immediately
        let removedWindowIds = windowController.removeAllWindows(forPid: pid)
        guard !removedWindowIds.isEmpty else {
            return
        }

        Logger.debug("Application terminated, pruned \(removedWindowIds.count) windows")
        validationRetryManager.cancelValidationRetry(for: pid)
        handleDestroyedWindows(removedWindowIds, reason: "application-termination", retarget: true)
    }

    internal func scheduleCapture(for application: NSRunningApplication, delay: TimeInterval) {
        let pid = application.processIdentifier
        let originalBundleId = application.bundleIdentifier  // Capture bundle ID to verify identity
        let appName = application.localizedName ?? "Unknown"

        Logger.debug("scheduleCapture: scheduling capture for \(appName) (pid \(pid)) in \(delay)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard !self.sleepWakeProtectionActive else {
                Logger.debug("scheduleCapture: aborting capture for pid \(pid) because sleep/wake protection is active")
                return
            }
            guard let refreshedApplication = NSRunningApplication(processIdentifier: pid) else {
                Logger.debug("scheduleCapture: pid \(pid) no longer running, aborting capture")
                return
            }

            // Verify the PID still belongs to the same application
            if let originalBundleId = originalBundleId,
               let refreshedBundleId = refreshedApplication.bundleIdentifier,
               originalBundleId != refreshedBundleId {
                Logger.debug("PID \(pid) has been reused by different app (was \(originalBundleId), now \(refreshedBundleId)), aborting capture")
                return
            }

            guard self.shouldManage(application: refreshedApplication, logRejection: true) else { return }

            _ = self.captureWindows(
                for: refreshedApplication,
                notifyDelegate: true,
                allowExisting: false
            )
        }
    }
}
