import Foundation

/// Pure policy for maintaining each WinShot snapshot's `lastActiveAt` (last-on-screen) time.
///
/// When a new arrangement is captured for a screen, the arrangement that was live until now has been
/// superseded, so its last-on-screen time should advance to the capture. The chooser spaces its
/// timeline by `lastActiveAt`, so identifying the right snapshot to stamp keeps a long-lived
/// arrangement near the front (when it was last used) instead of back when it was first established.
enum WinShotLastActivePolicy {
    /// The snapshot whose `lastActiveAt` should advance to the new capture's timestamp, or nil when
    /// nothing was superseded. Given the screen's snapshot list newest-first and the signature being
    /// captured, this is the front snapshot — but only when it is genuinely the live arrangement:
    ///
    /// - It must not already have been superseded. After the live arrangement's snapshot is removed
    ///   (e.g. a window in it closed; see `WinShotManager.removeSnapshotsContaining`), a stale older
    ///   snapshot can sit at the front, and must not be re-stamped as if it had just been on screen.
    /// - It must differ from the new arrangement. A same-signature capture is a refresh of the
    ///   current arrangement (e.g. the chooser-open recapture), which supersedes nothing and keeps
    ///   the current arrangement reading as "now".
    static func supersededSnapshotId(
        inNewestFirst snapshots: [WinShotSnapshot],
        newSignature: WinShotSnapshotOccupancySignature
    ) -> UUID? {
        guard let previousNewest = snapshots.first else {
            return nil
        }
        guard !previousNewest.hasBeenSuperseded else {
            return nil
        }
        guard WinShotSnapshotOccupancySignature(snapshot: previousNewest) != newSignature else {
            return nil
        }
        return previousNewest.id
    }
}
