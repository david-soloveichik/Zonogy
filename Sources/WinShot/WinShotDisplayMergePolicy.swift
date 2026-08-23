/// Pure policy for keeping WinShot snapshots reachable across display disconnects: which remaining
/// display takes a disconnected display's snapshots, and how the two lists combine into one.
import CoreGraphics
import Foundation

enum WinShotDisplayMergePolicy {
    /// The remaining display that hosts a disconnected display's snapshots: the one touching it along
    /// the longest edge in the arrangement they had before the disconnect (frames on the global Cocoa
    /// plane). Displays that do not touch rank by the gap between the frames, so the nearest wins;
    /// ties prefer the larger overlap facing the removed display, then the lowest display id. Nil when
    /// no display remains.
    static func hostScreenId(
        forRemovedFrame removed: CGRect,
        remainingFrames: [CGDirectDisplayID: CGRect]
    ) -> CGDirectDisplayID? {
        /// Distance between the two frames' nearest points (0 when they touch or overlap).
        func gap(_ other: CGRect) -> CGFloat {
            let dx = max(0, max(removed.minX, other.minX) - min(removed.maxX, other.maxX))
            let dy = max(0, max(removed.minY, other.minY) - min(removed.maxY, other.maxY))
            return hypot(dx, dy)
        }
        /// How far the frames overlap along the axis they face each other on — the shared edge when
        /// they touch (the other axis then overlaps by exactly 0, so the larger overlap is that edge).
        func facingOverlap(_ other: CGRect) -> CGFloat {
            let xOverlap = min(removed.maxX, other.maxX) - max(removed.minX, other.minX)
            let yOverlap = min(removed.maxY, other.maxY) - max(removed.minY, other.minY)
            return max(0, xOverlap, yOverlap)
        }

        return remainingFrames.min { lhs, rhs in
            if gap(lhs.value) != gap(rhs.value) {
                return gap(lhs.value) < gap(rhs.value)
            }
            if facingOverlap(lhs.value) != facingOverlap(rhs.value) {
                return facingOverlap(lhs.value) > facingOverlap(rhs.value)
            }
            return lhs.key < rhs.key
        }?.key
    }

    /// The per-display lists (keyed by hosting display, each newest-first) after `removedScreenId`
    /// disconnects. The removed display's live arrangement — its one snapshot not yet superseded, if
    /// any — ended when the display went away, so it is stamped as superseded at `disconnectedAt`.
    /// Its list then dissolves into `hostScreenId`'s, interleaved newest-first by creation time (the
    /// order every list keeps, and the order trimming removes from the back of); no merged snapshot
    /// can be mistaken for the host's live arrangement. With no host (no display remains) the list
    /// stays in place, stamped, for the display's return.
    static func lists(
        afterDisconnecting removedScreenId: CGDirectDisplayID,
        into hostScreenId: CGDirectDisplayID?,
        disconnectedAt: Date,
        from lists: [CGDirectDisplayID: [WinShotSnapshot]]
    ) -> [CGDirectDisplayID: [WinShotSnapshot]] {
        var lists = lists
        guard var removed = lists.removeValue(forKey: removedScreenId), !removed.isEmpty else {
            return lists
        }
        if let liveIndex = removed.firstIndex(where: { !$0.hasBeenSuperseded }) {
            removed[liveIndex].supersededAt = disconnectedAt
        }
        if let hostScreenId {
            lists[hostScreenId] = newestFirst(removed + (lists[hostScreenId] ?? []))
        } else {
            lists[removedScreenId] = removed
        }
        return lists
    }

    /// The per-display lists after `screenId` connects: every snapshot captured on it returns from
    /// whichever list hosts it (a chain of disconnects can have carried it along more than once), so
    /// the display lists its own snapshots again. Snapshots captured on a host while they were merged
    /// there belong to the host and stay.
    static func lists(
        afterConnecting screenId: CGDirectDisplayID,
        from lists: [CGDirectDisplayID: [WinShotSnapshot]]
    ) -> [CGDirectDisplayID: [WinShotSnapshot]] {
        var lists = lists
        var reclaimed = lists.removeValue(forKey: screenId) ?? []
        for (hostScreenId, hosted) in lists where hosted.contains(where: { $0.screenId == screenId }) {
            reclaimed += hosted.filter { $0.screenId == screenId }
            let remaining = hosted.filter { $0.screenId != screenId }
            lists[hostScreenId] = remaining.isEmpty ? nil : remaining
        }
        if !reclaimed.isEmpty {
            lists[screenId] = newestFirst(reclaimed)
        }
        return lists
    }

    private static func newestFirst(_ snapshots: [WinShotSnapshot]) -> [WinShotSnapshot] {
        snapshots.sorted { $0.createdAt > $1.createdAt }
    }
}
