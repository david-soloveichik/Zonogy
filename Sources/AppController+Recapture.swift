import Foundation
import AppKit

/// Window recapture pipeline shared by screen-change and wake-from-sleep flows.
///
/// After display topology changes or wake-from-sleep, this pipeline:
/// 1. Captures any previously unseen windows from running applications
/// 2. Identifies tracked windows that are unminimized but not in any zone
///    (tiled or temporary) and places them via the normal placement flow
extension AppController {
    /// Schedule a window recapture pass after the specified delay.
    /// Called from screen topology refresh (display changes) and wake-from-sleep.
    internal func scheduleWindowRecapture(delay: TimeInterval, reason: String) {
        // Clean up any completed work items first
        pendingRecaptureWorkItems.removeAll { $0.isCancelled }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // Abort if screens went to sleep after this work item was scheduled
            guard !self.screensAsleep else {
                Logger.debug("SleepWake: aborting \(reason) recapture because screens are asleep")
                return
            }

            Logger.debug("Attempting \(reason) recapture after \(delay) seconds")

            let (preCaptureManaged, prePlaceholders) = self.currentWindowCounts()

            // Recapture windows from all running applications
            let visibleBundleIds = self.bundleIdsWithVisibleWindows()
            var capturedCount = 0
            for application in NSWorkspace.shared.runningApplications {
                guard self.shouldManage(application: application, visibleBundleIds: visibleBundleIds) else {
                    continue
                }

                // Capture windows, allowing existing ones to be returned
                let capturedWindows = self.captureWindows(
                    for: application,
                    notifyDelegate: true,
                    allowExisting: true
                )
                if !capturedWindows.isEmpty {
                    capturedCount += capturedWindows.count
                    Logger.debug("Captured \(capturedWindows.count) windows for \(application.bundleIdentifier ?? "unknown") (pid \(application.processIdentifier))")
                }
            }

            // Identify tracked windows that are unminimized but not in any zone
            // (tiled or temporary) and place them using normal placement logic.
            var placedUnzonedCount = 0
            for window in self.windowController.allWindows {
                guard !window.isPlaceholder,
                      !window.isMinimized,
                      self.zoneKey(forManagedWindow: window) == nil,
                      !self.isWindowInTemporaryZone(window.windowId) else {
                    continue
                }
                Logger.debug("\(reason.capitalized) recapture: placing tracked but unzoned window \(window.windowId)")
                self.windowPlacementManager.placeNewWindow(window)
                placedUnzonedCount += 1
            }

            // Sync if we captured new windows or placed unzoned ones
            if capturedCount > 0 || placedUnzonedCount > 0 {
                self.syncWindowsToZones()
                // Log the result
                let (postCaptureManaged, postPlaceholders) = self.currentWindowCounts()

                Logger.debug("\(reason.capitalized) recapture after \(delay)s: captured \(capturedCount) windows, placed \(placedUnzonedCount) unzoned, managed: \(preCaptureManaged) -> \(postCaptureManaged), placeholders: \(prePlaceholders) -> \(postPlaceholders)")
            }
        }

        pendingRecaptureWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Cancel all pending recapture work items. Called when screens go to sleep.
    internal func cancelAllPendingRecaptureWorkItems() {
        for workItem in pendingRecaptureWorkItems {
            workItem.cancel()
        }
        pendingRecaptureWorkItems.removeAll()
    }
}
