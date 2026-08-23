import Foundation

/// Pure policy for maintaining each WinShot snapshot's `supersededAt` (end of its on-screen life).
///
/// When a new arrangement is captured for a screen, the arrangement that was live until now has been
/// superseded, so its last-on-screen time should advance to the capture. The chooser spaces its
/// timeline by `lastActiveAt`, so identifying the right snapshot to stamp keeps a long-lived
/// arrangement near the front (when it was last used) instead of back when it was first established.
enum WinShotLastActivePolicy {
    /// The snapshot whose `supersededAt` should be set to the new capture's timestamp, or nil when
    /// nothing was superseded. Given the screen's snapshot list newest-first and the signature being
    /// captured, this is the list's live snapshot — but only when it differs from the new arrangement:
    ///
    /// - The live snapshot is the one not yet superseded; a list holds at most one. It is normally the
    ///   front, but snapshots merged from a disconnected display (all superseded) can sit ahead of it.
    ///   There may be none: after the live arrangement's snapshot is removed (e.g. a window in it
    ///   closed; see `WinShotManager.removeSnapshotsContaining`), a stale older snapshot sits at the
    ///   front, and must not be re-stamped as if it had just been on screen.
    /// - A same-signature capture is a refresh of the current arrangement (e.g. the chooser-open
    ///   recapture), which supersedes nothing and keeps the current arrangement reading as "now".
    static func supersededSnapshotId(
        inNewestFirst snapshots: [WinShotSnapshot],
        newSignature: WinShotSnapshotOccupancySignature
    ) -> UUID? {
        guard let live = snapshots.first(where: { !$0.hasBeenSuperseded }) else {
            return nil
        }
        guard WinShotSnapshotOccupancySignature(snapshot: live) != newSignature else {
            return nil
        }
        return live.id
    }
}
