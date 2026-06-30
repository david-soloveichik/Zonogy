import Foundation
import AppKit

/// Handles NSWorkspace application launch/terminate/state-change events and schedules capture.
extension AppController {
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

    internal func handleApplicationTermination(_ application: NSRunningApplication?) {
        guard let application else {
            Logger.debug("NSWorkspace notification received: didTerminateApplication (no application payload)")
            return
        }

        let name = application.localizedName ?? "Unknown App"
        var details = "\(name), pid \(application.processIdentifier)"
        if let bundleId = application.bundleIdentifier {
            details += ", bundle \(bundleId)"
        }
        Logger.debug("NSWorkspace notification received: didTerminateApplication (\(details))")

        // Notify full-screen tracker that this app terminated
        notifyFullScreenTrackerOfAppTermination(pid: application.processIdentifier)
        clearUnmanagedWindowEdgeState(forPid: application.processIdentifier, reason: "application-termination")

        capturePipeline.cancelRetry(forPid: application.processIdentifier)
        // When an application terminates, remove all of its managed windows immediately
        let removedWindowIds = windowController.removeAllWindows(forPid: application.processIdentifier)
        if removedWindowIds.isEmpty {
            Logger.debug("Application terminated, but no managed windows were associated with pid \(application.processIdentifier)")
            return
        }

        Logger.debug("Application terminated, pruned \(removedWindowIds.count) windows")
        validationRetryManager.cancelValidationRetry(for: application.processIdentifier)
        handleDestroyedWindows(removedWindowIds, reason: "application-termination", retarget: true)
    }

    internal func scheduleCapture(for application: NSRunningApplication, delay: TimeInterval) {
        let pid = application.processIdentifier
        let originalBundleId = application.bundleIdentifier  // Capture bundle ID to verify identity
        let appName = application.localizedName ?? "Unknown"

        Logger.debug("scheduleCapture: scheduling capture for \(appName) (pid \(pid)) in \(delay)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard !self.screensAsleep else {
                Logger.debug("scheduleCapture: aborting capture for pid \(pid) because screens are asleep")
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
