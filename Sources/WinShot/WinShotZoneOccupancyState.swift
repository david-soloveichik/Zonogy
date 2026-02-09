/// Tracks per-screen zone occupancy for WinShot auto-save change detection.
import Foundation
import CoreGraphics

struct WinShotZoneOccupancyState: Equatable {
    /// Tiled-zone assignments keyed by zone index.
    let tiledOccupantsByZoneIndex: [Int: Int]
    /// Current temporary-zone occupant on the same screen, if any.
    let temporaryOccupantWindowId: Int?
}

enum WinShotZoneOccupancyChangeDetector {
    /// Returns the set of screen IDs whose occupancy state changed.
    static func changedScreenIds(
        previous: [CGDirectDisplayID: WinShotZoneOccupancyState],
        current: [CGDirectDisplayID: WinShotZoneOccupancyState]
    ) -> Set<CGDirectDisplayID> {
        var changed = Set<CGDirectDisplayID>()
        let allScreenIds = Set(previous.keys).union(current.keys)

        for screenId in allScreenIds where previous[screenId] != current[screenId] {
            changed.insert(screenId)
        }

        return changed
    }
}
