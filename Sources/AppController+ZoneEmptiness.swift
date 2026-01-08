/// Shared helpers for determining effective tiling-zone emptiness
import Foundation

extension AppController {
    /// A tiling zone is considered effectively empty if it has no occupant or only a placeholder occupant.
    func isZoneEffectivelyEmpty(_ zone: Zone) -> Bool {
        guard let existingId = zone.windowId else {
            return true
        }
        guard let existing = windowController.window(withId: existingId) else {
            return false
        }
        return existing.isPlaceholder
    }
}

