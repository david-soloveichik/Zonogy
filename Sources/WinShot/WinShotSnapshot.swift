/// Data model for a WinShot snapshot of a screen's window arrangement
import AppKit

struct WinShotSnapshot {
    let id: UUID
    let screenId: CGDirectDisplayID
    let createdAt: Date

    /// The most recent time this arrangement was the live on-screen layout. Starts equal to
    /// `createdAt` and advances to the capture time of whatever *different* arrangement next
    /// supersedes it (maintained in WinShotManager). The chooser spaces its timeline by this, not
    /// by `createdAt`, so an arrangement that stayed on screen a long time sits near the front
    /// (when it was last used) instead of back when it was first established.
    var lastActiveAt: Date

    /// Zone configuration at snapshot time
    let zoneCount: Int
    let zoneFrames: [Int: CGRect]  // zoneIndex -> frame

    /// Window frames at snapshot time (zoneIndex -> window frame in screen coordinates).
    /// Only populated for zones that had a non-placeholder window.
    let windowFrames: [Int: CGRect]

    /// Sticky Resize remembered tiled-window sizes captured at snapshot time (zoneIndex -> size).
    let rememberedTiledWindowSizesByZoneIndex: [Int: CGSize]

    /// Window assignments (zoneIndex -> identity)
    let zoneAssignments: [Int: WindowIdentity]

    /// Floating zone occupant, if any
    let floatingZoneOccupant: WindowIdentity?

    /// Frame of floating zone window at snapshot time (in screen coordinates)
    let floatingZoneFrame: CGRect?

    /// Which window was active when snapshot was created
    let activeWindowId: Int?

    /// Low-resolution screenshot. Populated asynchronously after creation: the snapshot is created
    /// with `nil` and filled in once the composited capture completes (see WinShotManager).
    var thumbnail: NSImage?

    /// True once this snapshot has been superseded by a later capture — its `lastActiveAt` has been
    /// advanced past `createdAt`. While false, the snapshot still represents the arrangement that was
    /// live up to the present (it sits at the front of its screen's list). Used to avoid re-stamping a
    /// stale snapshot that merely floated to the front after the live arrangement's snapshot was
    /// removed (e.g. a window in it closed).
    var hasBeenSuperseded: Bool {
        lastActiveAt != createdAt
    }

    /// Returns all window IDs in this snapshot (zones + floating zone)
    var allWindowIds: Set<Int> {
        var ids = Set(zoneAssignments.values.map { $0.windowId })
        if let floatingId = floatingZoneOccupant?.windowId {
            ids.insert(floatingId)
        }
        return ids
    }

    /// Tiling-zone occupant window identities ordered by ascending zone index. Drives the top row of
    /// the app-icon strip under each chooser thumbnail (one entry per occupied tiling zone, so two
    /// windows of the same app appear twice). The floating-zone occupant is shown on a separate row.
    var tilingOccupantsByZoneOrder: [WindowIdentity] {
        zoneAssignments.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Check if this snapshot contains a specific window identity
    func contains(windowId: Int) -> Bool {
        if zoneAssignments.values.contains(where: { $0.windowId == windowId }) {
            return true
        }
        if floatingZoneOccupant?.windowId == windowId {
            return true
        }
        return false
    }

    /// Check if this snapshot contains a window matching the given identity
    func contains(identity: WindowIdentity) -> Bool {
        if zoneAssignments.values.contains(where: { $0.windowId == identity.windowId }) {
            return true
        }
        if floatingZoneOccupant?.windowId == identity.windowId {
            return true
        }
        return false
    }

    /// Emit detailed debug logging describing the snapshot's contents, including
    /// zone configuration, window identities, floating-zone occupant, and
    /// which window (if any) was active when the snapshot was captured.
    func logDebugDetails(context: String) {
        let prefix = "WinShot snapshot \(id)"

        Logger.debug("\(prefix) \(context): screen=\(ScreenContextStore.logDescription(for: screenId)), zoneCount=\(zoneCount)")

        let sortedZoneIndices = zoneFrames.keys.sorted()
        for index in sortedZoneIndices {
            guard let frame = zoneFrames[index] else {
                continue
            }

            if let identity = zoneAssignments[index] {
                let bundle = identity.bundleIdentifier ?? "unknown"
                let title = identity.windowTitle ?? "untitled"
                let rememberedSizeDescription = rememberedTiledWindowSizesByZoneIndex[index].map {
                    ", rememberedSize=\($0)"
                } ?? ""
                Logger.debug(
                    "\(prefix) zone \(index): windowId=\(identity.windowId), bundle=\(bundle), title=\(title), frame=\(frame)\(rememberedSizeDescription)"
                )
            } else {
                Logger.debug("\(prefix) zone \(index): empty, frame=\(frame)")
            }
        }

        if let floatingOccupant = floatingZoneOccupant {
            let bundle = floatingOccupant.bundleIdentifier ?? "unknown"
            let title = floatingOccupant.windowTitle ?? "untitled"
            let frameStr = floatingZoneFrame.map { "\($0)" } ?? "nil"
            Logger.debug(
                "\(prefix) floating-zone: windowId=\(floatingOccupant.windowId), bundle=\(bundle), title=\(title), frame=\(frameStr)"
            )
        } else {
            Logger.debug("\(prefix) floating-zone: empty")
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

        if let floatingOccupant = floatingZoneOccupant, floatingOccupant.windowId == activeId {
            let bundle = floatingOccupant.bundleIdentifier ?? "unknown"
            let title = floatingOccupant.windowTitle ?? "untitled"
            Logger.debug(
                "\(prefix) activeWindowId=\(activeId) (floating-zone, bundle=\(bundle), title=\(title))"
            )
            return
        }

        Logger.debug("\(prefix) activeWindowId=\(activeId) (not present in snapshot)")
    }
}
