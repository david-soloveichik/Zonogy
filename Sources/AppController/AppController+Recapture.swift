import Foundation
import AppKit

/// Window recapture pipeline shared by screen-change and wake-from-sleep flows.
///
/// After display topology changes or wake-from-sleep, this pipeline:
/// 1. Captures any previously unseen windows from running applications
/// 2. Minimizes floating-zone occupants whose live position has drifted
///    onto a different screen than the one they were booked against
///    (macOS can silently relocate windows when displays reattach; the
///    new screen is unlikely to reflect any user intent so we hide the
///    window rather than guessing where it should land)
/// 3. Identifies tracked windows that are unminimized but not in any zone
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

            // Minimize floating-zone occupants whose live screen no longer matches their booked slot.
            let minimizedDriftedCount = self.minimizeDriftedFloatingZoneOccupants(reason: reason)

            // Place any tracked but unzoned windows.
            // This intentionally does not sync per placement; we do one sync below
            // to avoid re-entrant churn while iterating recapture candidates.
            let placedUnzonedCount = self.placeTrackedButUnzonedWindows(reason: reason)

            // Sync if we captured new windows, minimized drifted floating occupants, or placed unzoned ones.
            if capturedCount > 0 || minimizedDriftedCount > 0 || placedUnzonedCount > 0 {
                self.syncWindowsToZones()
                // Log the result
                let (postCaptureManaged, postPlaceholders) = self.currentWindowCounts()

                Logger.debug("\(reason.capitalized) recapture after \(delay)s: captured \(capturedCount) windows, minimized \(minimizedDriftedCount) drifted floating, placed \(placedUnzonedCount) unzoned, managed: \(preCaptureManaged) -> \(postCaptureManaged), placeholders: \(prePlaceholders) -> \(postPlaceholders)")
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
    ///
    /// Candidates on full-screen-paused screens are not pre-filtered here: `placeNewWindow`
    /// arbitrates per-window via `decideNewWindowPlacement`, which handles the native FS
    /// partial-pause path (place into the targeted zone on a non-paused screen, then
    /// re-raise the FS Space) and the deferral path uniformly.
    @discardableResult
    internal func placeTrackedButUnzonedWindows(reason: String) -> Int {
        withTrackedButUnzonedWindows(
            reason: reason,
            candidateKind: "recapture",
            restrictedToScreenId: nil,
            skipFullScreenPausedScreens: false,
            logSkipFullScreenPaused: false
        ) { window in
            Logger.debug("\(reason.capitalized): placing tracked but unzoned window \(window.windowId)")
            windowPlacementManager.placeNewWindow(window, requestSync: false)
        }
    }

    /// Minimize floating-zone occupants whose live position no longer sits on the
    /// screen their floating slot is booked against. macOS may silently relocate a
    /// floating window onto a different display when displays reattach; sync's
    /// Phase 5 cleanup preserves the stale floating slot and the tracked-but-unzoned
    /// recapture step explicitly skips floating-zone occupants, so without this
    /// pass such a window stays "managed but lost" under the placeholder of its
    /// new screen. The new screen is unlikely to reflect any specific user intent,
    /// so the window is minimized; the user can re-summon it when they need it.
    ///
    /// Uses the AX-element overload of `detectScreenId` so the live frame is
    /// queried directly, bypassing the cached `managed.screenDisplayId` shortcut.
    /// Returns the number of windows minimized.
    @discardableResult
    internal func minimizeDriftedFloatingZoneOccupants(reason: String) -> Int {
        let snapshot = floatingZoneCoordinator.occupants
        guard !snapshot.isEmpty else { return 0 }

        var minimizedCount = 0
        for (bookedScreenId, windowId) in snapshot {
            guard let managed = windowController.window(withId: windowId),
                  !managed.isMinimizedPerAccessibility,
                  let actualScreenId = detectScreenId(for: managed.backing.element),
                  actualScreenId != bookedScreenId else {
                continue
            }

            Logger.debug(
                "\(reason.capitalized): minimizing floating occupant window \(windowId); live frame on screen \(screenContextStore.loggingIndex(for: actualScreenId)) but booked on screen \(screenContextStore.loggingIndex(for: bookedScreenId))"
            )
            floatingZoneCoordinator.clear(
                windowId: windowId,
                minimize: true,
                reason: "\(reason)-floating-screen-drifted"
            )
            minimizedCount += 1
        }
        return minimizedCount
    }
}
