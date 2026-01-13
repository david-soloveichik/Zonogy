/// Shared helpers for determining effective tiling-zone emptiness
import Foundation

extension AppController {
    /// A tiling zone is considered effectively empty if it has no occupant.
    func isZoneEffectivelyEmpty(_ zone: Zone) -> Bool {
        return zone.occupantWindowId == nil
    }
}
