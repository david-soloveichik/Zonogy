import CoreGraphics
import Foundation

/// Pure policy identifying the unmanaged windows a Launcher would cover, so it can stay out of
/// their way: it does not auto-show over one, and yields to one that appears beneath it later.
///
/// Managed windows are reachable through the Launcher's own window list, so covering one is no
/// dead end; an unmanaged window is not, so the Launcher yields to it. Desktop icons never count.
///
/// Windows count within the given zone frames (empty tiling zones, whose placeholders let clicks
/// through to such windows — see `PlaceholderPassThroughPolicy`), using that policy's geometry
/// with every window treated as lying behind the zone's placeholder: the next sync re-raises
/// placeholders over whatever is within them, so current z-order is irrelevant, and a zone that
/// is only about to get its placeholder can be judged the same way.
enum LauncherCoveredWindowPolicy {
    /// Where the Launcher was last judged and the unmanaged windows beneath it then. Covering
    /// those was the user's (or the auto-show rule's) call; the Launcher yields only to later
    /// arrivals.
    struct Placement: Equatable {
        let frame: CGRect
        let toleratedWindowNumbers: Set<Int>
    }

    enum YieldDecision: Equatable {
        /// Keep the Launcher, carrying this placement forward.
        case keep(Placement)
        /// Dismiss the Launcher: an unmanaged window it was not placed over now lies beneath it.
        case yield
    }

    /// Decides what an open Launcher at `launcherFrame` does now that `coveredWindowNumbers`
    /// lie beneath it. With no placement yet, or after the Launcher moved (a target change, a
    /// zone resize, or the system shifting it), this reading becomes the new placement.
    static func yieldDecision(
        placement: Placement?,
        launcherFrame: CGRect,
        coveredWindowNumbers: Set<Int>
    ) -> YieldDecision {
        if let placement, placement.frame == launcherFrame, !coveredWindowNumbers.isSubset(of: placement.toleratedWindowNumbers) {
            return .yield
        }
        if let placement, placement.frame == launcherFrame {
            return .keep(placement)
        }
        return .keep(Placement(frame: launcherFrame, toleratedWindowNumbers: coveredWindowNumbers))
    }

    /// Window numbers of the unmanaged windows within `zoneFrames` that overlap `launcherFrame`
    /// (all in the rows' coordinate space). Slivers no wider or taller than `minOverlapDimension`
    /// are ignored.
    static func coveredUnmanagedWindowNumbers(
        launcherFrame: CGRect,
        zoneFrames: [CGRect],
        rows: [WindowServerWindowRow],
        zonogyPid: pid_t,
        managedWindowNumbers: Set<Int>,
        minOverlapDimension: CGFloat = 1
    ) -> Set<Int> {
        var covered = Set<Int>()
        for zoneFrame in zoneFrames {
            let holes = PlaceholderPassThroughPolicy.holes(placeholderFrame: zoneFrame, rowsBehind: rows, zonogyPid: zonogyPid)
            for hole in holes.windows where !managedWindowNumbers.contains(hole.windowNumber) {
                let overlap = hole.rect.intersection(launcherFrame)
                if !overlap.isNull, overlap.width > minOverlapDimension, overlap.height > minOverlapDimension {
                    covered.insert(hole.windowNumber)
                }
            }
        }
        return covered
    }
}
