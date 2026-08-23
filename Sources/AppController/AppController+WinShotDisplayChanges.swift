/// Keeps WinShot snapshots reachable across display disconnects: a removed display's arrangement is
/// auto-saved (mode permitting) and its snapshots merge onto the neighboring remaining display; they
/// return when the display reconnects.
import AppKit

extension AppController {
    /// A display is being removed (its windows are about to be minimized). Capture its arrangement
    /// the way Clear/Reset Zones would, then hand its snapshots to the remaining display that touched
    /// it along the longest edge in the arrangement they had before the removal
    /// (`framesBeforeRemoval`; a display that appeared in this same refresh has no such frame and is
    /// measured at its current one).
    internal func handleWinShotSnapshotsForRemovedScreen(
        _ context: ScreenContext,
        framesBeforeRemoval: [CGDirectDisplayID: CGRect]
    ) {
        let removedScreenId = context.descriptor.displayId
        autoSavePreClearWinShotSnapshotIfNeeded(in: context, clearReason: "display-removal")

        let remainingFrames = screenContexts.mapValues { remaining in
            framesBeforeRemoval[remaining.descriptor.displayId] ?? remaining.descriptor.cocoaBounds
        }
        let hostScreenId = WinShotDisplayMergePolicy.hostScreenId(
            forRemovedFrame: context.descriptor.cocoaBounds,
            remainingFrames: remainingFrames
        )
        winShotManager.handleScreenDisconnected(removedScreenId, hostScreenId: hostScreenId, at: Date())

        // A chooser on the removed display has nowhere to open anything; one on the host now lists
        // the merged snapshots.
        if winShotChooserController.currentScreenId == removedScreenId {
            winShotChooserController.hide()
        } else {
            refreshOpenWinShotChooser()
        }
    }

    /// A display was connected: its own snapshots return from wherever they were merged.
    internal func handleWinShotSnapshotsForAddedScreen(_ screenId: CGDirectDisplayID) {
        winShotManager.handleScreenConnected(screenId)
        refreshOpenWinShotChooser()
    }
}
