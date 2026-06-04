import Foundation

/// Pure predicate for the accessibility frame-retry chain: has a window's move/resize
/// settled? Settled = the origin is at the target AND the app accepted the AX write.
///
/// The subtle half is "accepted". A window that *accepts* the write but lands at a different
/// size (a min/max-size constraint) is settled: its frame is permanent, so retrying would
/// only loop and fight ActiveFit. A *rejected* write (e.g. a window queried just after
/// creation, before it can be resized) is a transient failure — not settled, so the chain
/// keeps retrying even at a correct origin. So we key on whether the write was accepted, not
/// on whether the resulting frame matches.
enum FrameRetryPolicy {
    /// - Parameters:
    ///   - originAtTarget: whether the window's current origin matches the target origin.
    ///   - writeAccepted: whether the most recent AX write (position and size) returned
    ///     success. `false` means the app rejected the write.
    /// - Returns: `true` if the frame has settled (the chain should stop retrying).
    static func hasSettled(originAtTarget: Bool, writeAccepted: Bool) -> Bool {
        originAtTarget && writeAccepted
    }
}
