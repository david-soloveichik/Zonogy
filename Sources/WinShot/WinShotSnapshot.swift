/// Data model for a WinShot snapshot of a screen's window arrangement
import AppKit

struct WinShotSnapshot {
    let id: UUID
    let screenId: CGDirectDisplayID
    let createdAt: Date

    /// Zone configuration at snapshot time
    let zoneCount: Int
    let zoneFrames: [Int: CGRect]  // zoneIndex -> frame

    /// Window assignments (zoneIndex -> identity)
    let zoneAssignments: [Int: WindowIdentity]

    /// Temporary zone occupant, if any
    let temporaryZoneOccupant: WindowIdentity?

    /// Which window was active when snapshot was created
    let activeWindowId: Int?

    /// Low-resolution screenshot
    let thumbnail: NSImage?

    /// Returns all window IDs in this snapshot (zones + temporary zone)
    var allWindowIds: Set<Int> {
        var ids = Set(zoneAssignments.values.map { $0.windowId })
        if let tempId = temporaryZoneOccupant?.windowId {
            ids.insert(tempId)
        }
        return ids
    }

    /// Check if this snapshot contains a specific window identity
    func contains(windowId: Int) -> Bool {
        if zoneAssignments.values.contains(where: { $0.windowId == windowId }) {
            return true
        }
        if temporaryZoneOccupant?.windowId == windowId {
            return true
        }
        return false
    }

    /// Check if this snapshot contains a window matching the given identity
    func contains(identity: WindowIdentity) -> Bool {
        if zoneAssignments.values.contains(where: { $0.windowId == identity.windowId }) {
            return true
        }
        if temporaryZoneOccupant?.windowId == identity.windowId {
            return true
        }
        return false
    }
}
