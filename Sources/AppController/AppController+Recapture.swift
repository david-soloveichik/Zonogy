import Foundation
import AppKit

/// Window recapture pipeline shared by screen-change and wake-from-sleep flows.
///
/// After display topology changes or wake-from-sleep, this pipeline:
/// 1. Captures any previously unseen windows from running applications
/// 2. Identifies tracked windows that are unminimized but not in any zone
///    (tiled or floating) and places them via the normal placement flow
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

            // Place any tracked but unzoned windows.
            // This intentionally does not sync per placement; we do one sync below
            // to avoid re-entrant churn while iterating recapture candidates.
            let placedUnzonedCount = self.placeTrackedButUnzonedWindows(reason: reason)

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

    /// Places any tracked windows that are unminimized but not assigned to any zone.
    /// Called after wake and screen changes to catch windows that
    /// were deminiaturized or created while events were suppressed.
    /// Returns the number of windows placed.
    @discardableResult
    internal func placeTrackedButUnzonedWindows(reason: String) -> Int {
        withTrackedButUnzonedWindows(
            reason: reason,
            candidateKind: "recapture",
            restrictedToScreenId: nil,
            skipFullScreenPausedScreens: true,
            logSkipFullScreenPaused: true
        ) { window in
            Logger.debug("\(reason.capitalized): placing tracked but unzoned window \(window.windowId)")
            windowPlacementManager.placeNewWindow(window, requestSync: false)
        }
    }
}
