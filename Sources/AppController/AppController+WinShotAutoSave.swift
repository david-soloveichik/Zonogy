/// Drives "after every change" WinShot auto-save: feeds each display's arrangement state to the
/// settle-timer scheduler whenever it may have changed, and captures a snapshot once an
/// arrangement settles.
import AppKit

extension AppController {
    /// Re-evaluate auto-save. Called wherever a display's arrangement may have changed: at the end
    /// of every full zone sync, after window moves and resizes, and when the relevant settings
    /// change. Computes each tracked display's arrangement state and lets the scheduler (re)arm or
    /// cancel per-display settle timers; the snapshot itself is captured later, only if the
    /// arrangement survives the configured delay. Cheap, and without effect when nothing changed.
    internal func evaluateWinShotAutoSave() {
        guard isWinShotChangeTrackingEnabled else {
            winShotAutoSaveScheduler.reset()
            return
        }

        var currentStates: [CGDirectDisplayID: WinShotArrangementState] = [:]
        for screenId in screenOrder {
            // Skip screens in, or still leaving, a full-screen Space — their tiling layout isn't
            // user-facing, and dropping them here cancels and forgets any pending settle timer.
            guard !isScreenInOrLeavingFullScreen(screenId) else {
                continue
            }
            // Only track arrangements that have something to capture; an all-empty screen produces no
            // snapshot (and dropping it here cleanly cancels a pending timer when a zone empties out).
            guard let state = currentWinShotArrangementState(on: screenId),
                  signatureHasOccupant(state.occupancy) else {
                continue
            }
            currentStates[screenId] = state
        }

        winShotAutoSaveScheduler.reconcile(
            currentStates: currentStates,
            delay: TimeInterval(winShotSettleDelaySeconds),
            onSettle: { [weak self] screenId, armedState in
                self?.captureWinShotSnapshotOnSettle(on: screenId, armedOccupancy: armedState.occupancy)
            }
        )
    }

    private func currentWinShotArrangementState(on screenId: CGDirectDisplayID) -> WinShotArrangementState? {
        guard let context = screenContexts[screenId],
              let occupancy = currentSnapshotOccupancySignature(on: screenId) else {
            return nil
        }
        let tiledWindowIds = Set(occupancy.tiledWindowIdsByZoneIndex.values)
        return WinShotArrangementState(
            occupancy: occupancy,
            zoneFrames: context.zoneController.allZones.map(\.frame),
            floatingWindowFrame: floatingZoneCoordinator.occupant(on: screenId)?.cachedFrame,
            stickyResizeSizes: rememberedManualResizeSizesByWindowId.filter { tiledWindowIds.contains($0.key) }
        )
    }

    /// Opening the chooser with change tracking on behaves as if Control-Command-/ were pressed right
    /// before it: capture the current arrangement now so it's present in the chooser from the start.
    /// Change tracking keeps running normally; settled captures just don't refresh an open chooser.
    internal func captureWinShotSnapshotForChooserOpenIfNeeded(on screenId: CGDirectDisplayID) {
        // Same rule as the settle captures: transition-time state is not a valid arrangement.
        guard isWinShotChangeTrackingEnabled, !isScreenInOrLeavingFullScreen(screenId) else {
            return
        }
        createWinShotSnapshot(on: screenId, reason: "winshot-chooser-open")
    }

    /// Fired by the scheduler once a screen's arrangement has been stable for the settle delay.
    private func captureWinShotSnapshotOnSettle(
        on screenId: CGDirectDisplayID,
        armedOccupancy: WinShotSnapshotOccupancySignature
    ) {
        // Conditions can change during the delay; re-check before capturing.
        guard isWinShotChangeTrackingEnabled,
              !isScreenInOrLeavingFullScreen(screenId),
              screenContexts[screenId] != nil else {
            return
        }
        // Only capture if the occupancy that armed the timer is still current, so an arrangement
        // that changed before the delay elapsed is never saved without actually persisting. Geometry
        // is not compared: the capture reads it fresh, so a geometry change that was not reported
        // (such as a frame Zonogy wrote) is saved rather than lost.
        guard currentSnapshotOccupancySignature(on: screenId) == armedOccupancy else {
            return
        }
        // Settled captures are silent: they never refresh an open chooser, so nothing pops in while
        // the user is mid-selection (the snapshot appears the next time the chooser opens).
        createWinShotSnapshot(on: screenId, reason: "arrangement-settled", refreshChooser: false)
    }

    /// A display entering full screen hides its arrangement and suspends its change tracking, so
    /// changes whose settle delay had not elapsed would go uncaptured. The zone bookkeeping still
    /// holds the pre-full-screen arrangement at this point, so capture it now; a capture with the
    /// same occupancy signature as the newest snapshot replaces it as usual, refreshing geometry
    /// and remembered sizes the signature does not cover. Native full screen only: it serves the
    /// chooser opening on a natively paused display, and a heuristic pause discovered by a startup
    /// or rescan sweep would capture seeded state that was never an arrangement.
    internal func captureWinShotSnapshotOnFullScreenPauseIfNeeded(on screenId: CGDirectDisplayID) {
        guard isWinShotChangeTrackingEnabled,
              fullScreenTracker.fullScreenWindowInfo(for: screenId)?.isNativeFullScreen == true,
              let signature = currentSnapshotOccupancySignature(on: screenId),
              signatureHasOccupant(signature) else {
            return
        }
        createWinShotSnapshot(on: screenId, reason: "full-screen-entered")
    }

    private func signatureHasOccupant(_ signature: WinShotSnapshotOccupancySignature) -> Bool {
        !signature.tiledWindowIdsByZoneIndex.isEmpty || signature.floatingZoneWindowId != nil
    }
}
