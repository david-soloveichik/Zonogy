/// Manages per-screen WinShot snapshot storage and lifecycle
import AppKit
import OSLog

final class WinShotManager {
    private static let thumbnailHeight: CGFloat = 200

    /// Each display's snapshots, newest-first, keyed by the display whose chooser lists them. That is
    /// the display a snapshot was captured on (`WinShotSnapshot.screenId`) except while that display is
    /// disconnected, when its snapshots are hosted on a neighboring display's list instead.
    private var snapshots: [CGDirectDisplayID: [WinShotSnapshot]] = [:]

    /// Invoked on the main queue once a snapshot's asynchronously captured thumbnail is ready, so an
    /// open chooser can refresh. Not fired for captures created with `notifiesThumbnailReady: false`.
    var onThumbnailReady: ((CGDirectDisplayID, UUID) -> Void)?

    // MARK: - Snapshot Access

    /// Get all snapshots for a screen, ordered by creation time (newest first)
    func snapshots(for screenId: CGDirectDisplayID) -> [WinShotSnapshot] {
        return snapshots[screenId] ?? []
    }

    /// Find a snapshot by its unique ID
    func snapshot(withId id: UUID) -> WinShotSnapshot? {
        guard let location = locate(id) else { return nil }
        return snapshots[location.screenId]?[location.index]
    }

    /// Check if there are any snapshots for a screen
    func hasSnapshots(for screenId: CGDirectDisplayID) -> Bool {
        guard let screenSnapshots = snapshots[screenId] else { return false }
        return !screenSnapshots.isEmpty
    }

    // MARK: - Snapshot Creation

    /// Creates a snapshot for the given screen if eligible. `floatingZoneFrame` is the floating
    /// occupant's current frame in screen coordinates, or nil when unknown (restoring then centers it).
    /// Returns the created snapshot, or nil if creation failed or was skipped
    func createSnapshot(
        screenId: CGDirectDisplayID,
        zoneController: ZoneController,
        windowController: WindowController,
        screenDescriptor: ScreenDescriptor,
        floatingZoneOccupant: ManagedWindow?,
        floatingZoneFrame: CGRect?,
        rememberedStickyResizeSizesByWindowId: [Int: CGSize],
        activeWindowId: Int?,
        reason: String,
        notifiesThumbnailReady: Bool
    ) -> WinShotSnapshot? {
        // Collect zone data
        let zones = zoneController.allZones
        let zoneCount = zones.count

        var zoneFrames: [Int: CGRect] = [:]
        var zoneAssignments: [Int: WindowIdentity] = [:]
        // Per-window placements + empty-zone rects feed the composited thumbnail (see captureThumbnail).
        var tiledPlacements: [WinShotThumbnailComposer.Placement] = []
        var emptyZoneRects: [CGRect] = []

        for zone in zones {
            zoneFrames[zone.index] = zone.frame

            if let windowId = zone.occupantWindowId,
               let managed = windowController.window(withId: windowId) {
                zoneAssignments[zone.index] = WindowIdentity.make(from: managed)
                tiledPlacements.append(
                    WinShotThumbnailComposer.Placement(
                        cgWindowId: CGWindowID(managed.backing.cgWindowId),
                        destRect: zone.frame
                    )
                )
            } else {
                emptyZoneRects.append(zone.frame)
            }
        }

        let floatingIdentity = floatingZoneOccupant.map { WindowIdentity.make(from: $0) }

        // Placement for the floating occupant (drawn on top at its actual frame; skipped if unknown).
        let floatingPlacement: WinShotThumbnailComposer.Placement? = {
            guard let floatingOccupant = floatingZoneOccupant, let frame = floatingZoneFrame else {
                return nil
            }
            return WinShotThumbnailComposer.Placement(
                cgWindowId: CGWindowID(floatingOccupant.backing.cgWindowId),
                destRect: frame
            )
        }()

        // Check eligibility: must have at least one non-placeholder window
        let hasWindows = !zoneAssignments.isEmpty || floatingIdentity != nil
        guard hasWindows else {
            Logger.debug("WinShot: Skipping snapshot - no windows on \(ScreenContextStore.logDescription(for: screenId))")
            return nil
        }

        // Check for duplicate occupancy signature (zone assignments + present empty zones).
        let occupancySignature = WinShotSnapshotOccupancySignature(
            presentZoneIndices: zoneFrames.keys,
            tiledWindowIdsByZoneIndex: zoneAssignments.mapValues { $0.windowId },
            floatingZoneWindowId: floatingIdentity?.windowId
        )
        // If a *different* arrangement was live in this screen's list until now, it has just been
        // superseded, so its on-screen life ends at this capture's timestamp (applied after insertion
        // below). Resolved before any same-signature replacement deletion so the lookup sees the
        // pre-capture list. The policy ignores a same-signature refresh (e.g. the chooser-open
        // recapture of the current arrangement, which supersedes nothing) and finds nothing when the
        // live arrangement's snapshot was removed (e.g. a window in it closed).
        let supersededSnapshotId = WinShotLastActivePolicy.supersededSnapshotId(
            inNewestFirst: snapshots[screenId] ?? [],
            newSignature: occupancySignature
        )

        // Reuse the replaced snapshot's ID for a same-occupancy capture, so identity stays stable across
        // refreshes — e.g. a silent background re-capture won't invalidate an ID an open chooser is
        // currently displaying.
        let replacedSnapshotId = findSnapshotWithSameOccupancySignature(occupancySignature, on: screenId)
        if let replacedSnapshotId {
            Logger.debug("WinShot: Replacing existing snapshot \(replacedSnapshotId) with same occupancy signature")
            deleteSnapshot(replacedSnapshotId)
        }

        let rememberedTiledWindowSizesByZoneIndex = WinShotStickyResizeSnapshotMapping.snapshotSizesByZoneIndex(
            zoneAssignments: zoneAssignments,
            rememberedSizesByWindowId: rememberedStickyResizeSizesByWindowId
        )

        // Create snapshot. The thumbnail is composited asynchronously from per-window captures and
        // filled in once it arrives — see captureThumbnail(...) below.
        let createdAt = Date()
        let snapshot = WinShotSnapshot(
            id: replacedSnapshotId ?? UUID(),
            screenId: screenId,
            createdAt: createdAt,
            supersededAt: nil,
            layoutBounds: zoneController.layoutBounds,
            zoneCount: zoneCount,
            zoneFrames: zoneFrames,
            rememberedTiledWindowSizesByZoneIndex: rememberedTiledWindowSizesByZoneIndex,
            zoneAssignments: zoneAssignments,
            floatingZoneOccupant: floatingIdentity,
            floatingZoneFrame: floatingZoneFrame,
            activeWindowId: activeWindowId,
            thumbnail: nil
        )

        // Store snapshot
        addSnapshot(snapshot, for: screenId)

        // The superseded arrangement was live right up until this capture, so its on-screen life
        // ends now. Done after insertion so the lookup sees the final list.
        if let supersededSnapshotId {
            markSuperseded(supersededSnapshotId, at: createdAt)
        }

        // Kick off the asynchronous per-window capture + composite now that the snapshot is stored.
        captureThumbnail(
            forSnapshot: snapshot.id,
            createdAt: snapshot.createdAt,
            displaySize: screenDescriptor.cocoaBounds.size,
            tiled: tiledPlacements,
            floating: floatingPlacement,
            emptyZoneRects: emptyZoneRects,
            notifiesReady: notifiesThumbnailReady
        )

        ZonogySignposts.pointsOfInterest.emitEvent(
            "WinShotSnapshotCreated",
            "screenId=\(screenId) tiled=\(zoneAssignments.count) floating=\(floatingIdentity != nil ? 1 : 0, privacy: .public) reason=\(reason, privacy: .public)"
        )

        Logger.debug(
            "WinShot: Created snapshot \(snapshot.id) on \(ScreenContextStore.logDescription(for: screenId)) with \(zoneAssignments.count) zone windows + \(floatingIdentity != nil ? 1 : 0) floating (reason: \(reason))"
        )
        snapshot.logDebugDetails(context: "created (reason: \(reason))")

        return snapshot
    }

    // MARK: - Snapshot Deletion

    /// Delete a snapshot by its ID
    func deleteSnapshot(_ id: UUID) {
        guard let location = locate(id) else { return }
        snapshots[location.screenId]?.remove(at: location.index)
        Logger.debug("WinShot: Deleted snapshot \(id) from \(ScreenContextStore.logDescription(for: location.screenId))")
    }

    /// Remove all snapshots containing a specific window ID
    /// Called when a window is closed
    func removeSnapshotsContaining(windowId: Int) {
        var removedCount = 0
        for screenId in snapshots.keys {
            let before = snapshots[screenId]?.count ?? 0
            snapshots[screenId]?.removeAll { $0.contains(windowId: windowId) }
            let after = snapshots[screenId]?.count ?? 0
            removedCount += (before - after)
        }

        if removedCount > 0 {
            Logger.debug("WinShot: Removed \(removedCount) snapshot(s) containing window \(windowId)")
        }
    }

    /// Remove all snapshots containing a window matching the given identity
    func removeSnapshotsContaining(identity: WindowIdentity) {
        removeSnapshotsContaining(windowId: identity.windowId)
    }

    /// Clear all snapshots for a specific screen
    func clearSnapshots(for screenId: CGDirectDisplayID) {
        let count = snapshots[screenId]?.count ?? 0
        snapshots[screenId] = nil
        if count > 0 {
            Logger.debug("WinShot: Cleared \(count) snapshot(s) for \(ScreenContextStore.logDescription(for: screenId))")
        }
    }

    /// Clear all snapshots
    func clearAllSnapshots() {
        let totalCount = snapshots.values.reduce(0) { $0 + $1.count }
        snapshots.removeAll()
        if totalCount > 0 {
            Logger.debug("WinShot: Cleared all \(totalCount) snapshot(s)")
        }
    }

    /// Enforces the configured per-screen snapshot limit immediately across all screens.
    func enforceConfiguredSnapshotLimit() {
        let maxPerScreen = WinShotPreferencesStore.loadMaxSnapshotsStored()
        for screenId in snapshots.keys {
            trimSnapshotsIfNeeded(for: screenId, maxPerScreen: maxPerScreen)
        }
    }

    // MARK: - Display Disconnect / Reconnect

    /// A display was disconnected at `disconnectedAt`, ending the on-screen life of its live
    /// arrangement. Its snapshots move onto `hostScreenId`, whose chooser shows them alongside the
    /// host's own (opening there, fitted) until the display returns; the host's limit applies to the
    /// merged list right away, so the oldest snapshots of either display may be dropped. With no host
    /// (no display remains) they stay put for the display's return.
    func handleScreenDisconnected(
        _ removedScreenId: CGDirectDisplayID,
        hostScreenId: CGDirectDisplayID?,
        at disconnectedAt: Date
    ) {
        let removedCount = snapshots[removedScreenId]?.count ?? 0
        guard removedCount > 0 else { return }
        snapshots = WinShotDisplayMergePolicy.lists(
            afterDisconnecting: removedScreenId,
            into: hostScreenId,
            disconnectedAt: disconnectedAt,
            from: snapshots
        )
        guard let hostScreenId else {
            Logger.debug("WinShot: No display remains to host the \(removedCount) snapshot(s) of removed \(ScreenContextStore.logDescription(for: removedScreenId))")
            return
        }
        trimSnapshotsIfNeeded(for: hostScreenId, maxPerScreen: WinShotPreferencesStore.loadMaxSnapshotsStored())
        Logger.debug(
            "WinShot: Merged \(removedCount) snapshot(s) of removed \(ScreenContextStore.logDescription(for: removedScreenId)) onto \(ScreenContextStore.logDescription(for: hostScreenId))"
        )
    }

    /// A display was connected: every surviving snapshot captured on it returns from wherever it was
    /// merged, so the display's chooser lists its own snapshots again.
    func handleScreenConnected(_ screenId: CGDirectDisplayID) {
        let countBefore = snapshots[screenId]?.count ?? 0
        snapshots = WinShotDisplayMergePolicy.lists(afterConnecting: screenId, from: snapshots)
        let returnedCount = (snapshots[screenId]?.count ?? 0) - countBefore
        guard returnedCount > 0 else { return }
        trimSnapshotsIfNeeded(for: screenId, maxPerScreen: WinShotPreferencesStore.loadMaxSnapshotsStored())
        Logger.debug(
            "WinShot: Returned \(returnedCount) snapshot(s) to reconnected \(ScreenContextStore.logDescription(for: screenId))"
        )
    }

    // MARK: - Private Helpers

    /// Where a snapshot is stored, by id — on whichever display's list currently hosts it.
    private func locate(_ id: UUID) -> (screenId: CGDirectDisplayID, index: Int)? {
        for (screenId, screenSnapshots) in snapshots {
            if let index = screenSnapshots.firstIndex(where: { $0.id == id }) {
                return (screenId, index)
            }
        }
        return nil
    }

    private func addSnapshot(_ snapshot: WinShotSnapshot, for screenId: CGDirectDisplayID) {
        if snapshots[screenId] == nil {
            snapshots[screenId] = []
        }

        // Insert at the beginning (newest first)
        snapshots[screenId]?.insert(snapshot, at: 0)

        let maxPerScreen = WinShotPreferencesStore.loadMaxSnapshotsStored()
        trimSnapshotsIfNeeded(for: screenId, maxPerScreen: maxPerScreen)
    }

    private func trimSnapshotsIfNeeded(for screenId: CGDirectDisplayID, maxPerScreen: Int) {
        guard snapshots[screenId] != nil else {
            return
        }

        while let count = snapshots[screenId]?.count, count > maxPerScreen {
            let removed = snapshots[screenId]?.removeLast()
            Logger.debug(
                "WinShot: Removed oldest snapshot \(removed?.id.uuidString ?? "unknown") to stay within limit \(maxPerScreen)"
            )
        }
    }

    private func findSnapshotWithSameOccupancySignature(
        _ signature: WinShotSnapshotOccupancySignature,
        on screenId: CGDirectDisplayID
    ) -> UUID? {
        guard let screenSnapshots = snapshots[screenId] else { return nil }

        for snapshot in screenSnapshots {
            if WinShotSnapshotOccupancySignature(snapshot: snapshot) == signature {
                return snapshot.id
            }
        }
        return nil
    }

    /// Asynchronously build the composited thumbnail (per-window captures placed at their zone rects)
    /// for a freshly created snapshot and fill it in when it arrives. `notifiesReady`
    /// gates `onThumbnailReady` so silent captures don't disturb an open chooser even once their image
    /// lands. `createdAt` identifies this exact snapshot instance: a same-occupancy capture reuses the id
    /// but gets a fresh `createdAt`, so a stale in-flight capture is dropped (it neither clobbers the
    /// newer thumbnail nor refreshes the chooser). The snapshot is found by id when the image lands,
    /// since it may have moved to another display's list meanwhile (a display-removal capture is
    /// merged onto the neighbor right away).
    private func captureThumbnail(
        forSnapshot id: UUID,
        createdAt: Date,
        displaySize: CGSize,
        tiled: [WinShotThumbnailComposer.Placement],
        floating: WinShotThumbnailComposer.Placement?,
        emptyZoneRects: [CGRect],
        notifiesReady: Bool
    ) {
        let signpostState = ZonogySignposts.pointsOfInterest.beginInterval(
            "WinShotCaptureThumbnail",
            "snapshot=\(id)"
        )

        WinShotThumbnailComposer.composeThumbnail(
            displaySize: displaySize,
            tiled: tiled,
            floating: floating,
            emptyZoneRects: emptyZoneRects,
            targetHeight: Self.thumbnailHeight
        ) { [weak self] thumbnail in
            // Delivered on the main queue.
            ZonogySignposts.pointsOfInterest.endInterval("WinShotCaptureThumbnail", signpostState)

            guard let self, let thumbnail else {
                return
            }

            // Apply only if this exact snapshot instance is still stored. Drops captures whose snapshot
            // was trimmed/deleted, or superseded by a newer same-id capture (fresh createdAt).
            guard let hostScreenId = self.setThumbnail(thumbnail, forSnapshot: id, createdAt: createdAt) else {
                return
            }

            if notifiesReady {
                self.onThumbnailReady?(hostScreenId, id)
            }
        }
    }

    /// End a stored snapshot's on-screen life at `date`. No-op if the snapshot is no longer stored
    /// (e.g. trimmed away in this same capture).
    private func markSuperseded(_ id: UUID, at date: Date) {
        guard let location = locate(id) else { return }
        snapshots[location.screenId]?[location.index].supersededAt = date
    }

    /// Update a stored snapshot's thumbnail in place, matching by id *and* `createdAt` so a stale
    /// in-flight capture can't write onto a newer same-id snapshot. Returns the display whose list
    /// holds the snapshot, or nil if no such snapshot is currently stored.
    private func setThumbnail(_ thumbnail: NSImage, forSnapshot id: UUID, createdAt: Date) -> CGDirectDisplayID? {
        guard let location = locate(id),
              snapshots[location.screenId]?[location.index].createdAt == createdAt else {
            return nil
        }
        snapshots[location.screenId]?[location.index].thumbnail = thumbnail
        return location.screenId
    }
}
