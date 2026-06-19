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
            // Skip screens paused for a full-screen Space — their tiling layout isn't user-facing.
            guard !isScreenPausedForFullScreen(screenId) else {
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
        guard isWinShotOccupancyChangeAutoSaveEnabled else {
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
              !isScreenPausedForFullScreen(screenId),
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

    private func signatureHasOccupant(_ signature: WinShotSnapshotOccupancySignature) -> Bool {
        !signature.tiledWindowIdsByZoneIndex.isEmpty || signature.floatingZoneWindowId != nil
    }
}
