/// Pure selection logic for retargeting after zone removal in "targeting follows focus" mode.
///
/// Priority: (1) active window's zone, (2) most recent in-zone window, (3) zone 1 on removed screen.

import CoreGraphics

enum FollowsFocusZoneRemovalPolicy {
    /// A window candidate for retargeting, with its zone placement info.
    struct Candidate {
        let windowId: Int
        /// Tiling zone index, or nil if not in a tiling zone.
        let zoneIndex: Int?
        let screenId: CGDirectDisplayID
        let isInFloatingZone: Bool
    }

    /// Select the retarget destination after a zone is removed in follows-focus mode.
    ///
    /// - Parameters:
    ///   - activeCandidate: The currently focused managed window (if any).
    ///   - recencyCandidates: All managed windows ordered by recency (most recent first).
    ///   - removedIndex: The index of the zone being removed.
    ///   - removedScreenId: The screen of the zone being removed.
    static func selectDestination(
        activeCandidate: Candidate?,
        recencyCandidates: [Candidate],
        removedIndex: Int,
        removedScreenId: CGDirectDisplayID
    ) -> TargetedZoneManager.TargetedDestination {
        // (1) Try active/focused managed window (skip if it's in the zone being removed)
        if let active = activeCandidate,
           !isInRemovedZone(active, removedIndex: removedIndex, removedScreenId: removedScreenId),
           let dest = destination(for: active, removedIndex: removedIndex, removedScreenId: removedScreenId) {
            return dest
        }

        // (2) Try the most recently active managed window that is in a zone
        //     (skip the window sitting in the zone being removed — its zoneIndex is stale)
        for candidate in recencyCandidates {
            if isInRemovedZone(candidate, removedIndex: removedIndex, removedScreenId: removedScreenId) {
                continue
            }
            if let dest = destination(for: candidate, removedIndex: removedIndex, removedScreenId: removedScreenId) {
                return dest
            }
        }

        // (3) Fallback: zone 1 on the same screen
        return .tiled(ZoneKey(screenId: removedScreenId, index: 1))
    }

    private static func isInRemovedZone(
        _ candidate: Candidate,
        removedIndex: Int,
        removedScreenId: CGDirectDisplayID
    ) -> Bool {
        candidate.zoneIndex == removedIndex && candidate.screenId == removedScreenId
    }

    /// Returns the tiled or floating destination for a candidate, adjusting the zone index if needed.
    private static func destination(
        for candidate: Candidate,
        removedIndex: Int,
        removedScreenId: CGDirectDisplayID
    ) -> TargetedZoneManager.TargetedDestination? {
        if let zoneIndex = candidate.zoneIndex {
            let adjustedIndex = (candidate.screenId == removedScreenId && zoneIndex > removedIndex)
                ? zoneIndex - 1
                : zoneIndex
            return .tiled(ZoneKey(screenId: candidate.screenId, index: adjustedIndex))
        }

        if candidate.isInFloatingZone {
            return .floating(screenId: candidate.screenId)
        }

        return nil
    }
}
