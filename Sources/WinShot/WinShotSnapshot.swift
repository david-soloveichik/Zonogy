/// Data model for a WinShot snapshot of a screen's window arrangement
import AppKit

struct WinShotSnapshot {
    let id: UUID
    let screenId: CGDirectDisplayID
    let createdAt: Date

    /// Zone configuration at snapshot time
    let zoneCount: Int
    let zoneFrames: [Int: CGRect]  // zoneIndex -> frame

    /// Window frames at snapshot time (zoneIndex -> window frame in screen coordinates).
    /// Only populated for zones that had a non-placeholder window.
    let windowFrames: [Int: CGRect]

    /// Window assignments (zoneIndex -> identity)
    let zoneAssignments: [Int: WindowIdentity]

    /// Temporary zone occupant, if any
    let temporaryZoneOccupant: WindowIdentity?

    /// Frame of temporary zone window at snapshot time (in screen coordinates)
    let temporaryZoneFrame: CGRect?

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

    /// Emit detailed debug logging describing the snapshot's contents, including
    /// zone configuration, window identities, temporary-zone occupant, and
    /// which window (if any) was active when the snapshot was captured.
    func logDebugDetails(context: String) {
        let prefix = "WinShot snapshot \(id)"

        Logger.debug("\(prefix) \(context): screenId=\(screenId), zoneCount=\(zoneCount)")

        let sortedZoneIndices = zoneFrames.keys.sorted()
        for index in sortedZoneIndices {
            guard let frame = zoneFrames[index] else {
                continue
            }

            if let identity = zoneAssignments[index] {
                let bundle = identity.bundleIdentifier ?? "unknown"
                let title = identity.windowTitle ?? "untitled"
                Logger.debug(
                    "\(prefix) zone \(index): windowId=\(identity.windowId), bundle=\(bundle), title=\(title), frame=\(frame)"
                )
            } else {
                Logger.debug("\(prefix) zone \(index): empty, frame=\(frame)")
            }
        }

        if let temp = temporaryZoneOccupant {
            let bundle = temp.bundleIdentifier ?? "unknown"
            let title = temp.windowTitle ?? "untitled"
            let frameStr = temporaryZoneFrame.map { "\($0)" } ?? "nil"
            Logger.debug(
                "\(prefix) temporary-zone: windowId=\(temp.windowId), bundle=\(bundle), title=\(title), frame=\(frameStr)"
            )
        } else {
            Logger.debug("\(prefix) temporary-zone: empty")
        }

        guard let activeId = activeWindowId else {
            Logger.debug("\(prefix) activeWindowId=nil")
            return
        }

        if let (zoneIndex, identity) = zoneAssignments.first(where: { $0.value.windowId == activeId }) {
            let bundle = identity.bundleIdentifier ?? "unknown"
            let title = identity.windowTitle ?? "untitled"
            Logger.debug(
                "\(prefix) activeWindowId=\(activeId) (zone \(zoneIndex), bundle=\(bundle), title=\(title))"
            )
            return
        }

        if let temp = temporaryZoneOccupant, temp.windowId == activeId {
            let bundle = temp.bundleIdentifier ?? "unknown"
            let title = temp.windowTitle ?? "untitled"
            Logger.debug(
                "\(prefix) activeWindowId=\(activeId) (temporary-zone, bundle=\(bundle), title=\(title))"
            )
            return
        }

        Logger.debug("\(prefix) activeWindowId=\(activeId) (not present in snapshot)")
    }
}
