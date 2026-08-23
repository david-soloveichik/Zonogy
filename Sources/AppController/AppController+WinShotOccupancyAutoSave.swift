/// Drives occupancy-change WinShot auto-save: feeds per-screen occupancy to the settle-timer
/// scheduler after each full zone sync, and captures a snapshot once an arrangement settles.
import AppKit

extension AppController {
    /// Re-evaluate occupancy-change auto-save. Called at the end of every full zone sync (and when
    /// the relevant settings change). Computes each tracked screen's occupancy signature and lets the
    /// scheduler (re)arm or cancel per-screen settle timers; the snapshot itself is captured later,
    /// only if the arrangement survives the configured delay.
    internal func evaluateWinShotOccupancyAutoSave() {
        guard isWinShotOccupancyChangeAutoSaveEnabled else {
            winShotOccupancyAutoSaveScheduler.reset()
            return
        }

        var currentSignatures: [CGDirectDisplayID: WinShotSnapshotOccupancySignature] = [:]
        for screenId in screenOrder {
            // Skip screens in, or still leaving, a full-screen Space — their tiling layout isn't
            // user-facing, and dropping them here cancels and forgets any pending settle timer.
            guard !isScreenInOrLeavingFullScreen(screenId) else {
                continue
            }
            // Only track arrangements that have something to capture; an all-empty screen produces no
            // snapshot (and dropping it here cleanly cancels a pending timer when a zone empties out).
            guard let signature = currentSnapshotOccupancySignature(on: screenId),
                  signatureHasOccupant(signature) else {
                continue
            }
            currentSignatures[screenId] = signature
        }

        winShotOccupancyAutoSaveScheduler.handleSync(
            currentSignatures: currentSignatures,
            delay: TimeInterval(winShotOccupancySettleDelaySeconds),
            onSettle: { [weak self] screenId, armedSignature in
                self?.captureWinShotSnapshotOnOccupancySettled(on: screenId, armedSignature: armedSignature)
            }
        )
    }

    /// Opening the chooser in occupancy-change mode behaves as if Control-Command-/ were pressed right
    /// before it: capture the current arrangement now so it's present in the chooser from the start.
    /// Occupancy tracking keeps running normally; settled captures just don't refresh an open chooser.
    internal func captureWinShotSnapshotForChooserOpenIfNeeded(on screenId: CGDirectDisplayID) {
        // Same rule as the settle captures: transition-time state is not a valid arrangement.
        guard isWinShotOccupancyChangeAutoSaveEnabled, !isScreenInOrLeavingFullScreen(screenId) else {
            return
        }
        createWinShotSnapshot(on: screenId, reason: "winshot-chooser-open")
    }

    /// Fired by the scheduler once a screen's arrangement has been stable for the settle delay.
    private func captureWinShotSnapshotOnOccupancySettled(
        on screenId: CGDirectDisplayID,
        armedSignature: WinShotSnapshotOccupancySignature
    ) {
        // Conditions can change during the delay; re-check before capturing.
        guard isWinShotOccupancyChangeAutoSaveEnabled,
              !isScreenInOrLeavingFullScreen(screenId),
              screenContexts[screenId] != nil else {
            return
        }
        // Only capture if the arrangement that armed the timer is still current, so an arrangement
        // that changed before the delay elapsed is never saved without actually persisting.
        guard currentSnapshotOccupancySignature(on: screenId) == armedSignature else {
            return
        }
        // Settled captures are silent: they never refresh an open chooser, so nothing pops in while
        // the user is mid-selection (the snapshot appears the next time the chooser opens).
        createWinShotSnapshot(on: screenId, reason: "occupancy-settled", refreshChooser: false)
    }

    /// A display entering full screen hides its arrangement and suspends its occupancy tracking, so
    /// changes whose settle delay had not elapsed would go uncaptured. The zone bookkeeping still
    /// holds the pre-full-screen arrangement at this point, so capture it now; a capture with the
    /// same occupancy signature as the newest snapshot replaces it as usual, refreshing geometry
    /// and remembered sizes the signature does not cover. Native full screen only: it serves the
    /// chooser opening on a natively paused display, and a heuristic pause discovered by a startup
    /// or rescan sweep would capture seeded state that was never an arrangement.
    internal func captureWinShotSnapshotOnFullScreenPauseIfNeeded(on screenId: CGDirectDisplayID) {
        guard isWinShotOccupancyChangeAutoSaveEnabled,
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
