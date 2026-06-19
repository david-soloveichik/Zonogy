/// Manages per-screen WinShot snapshot storage and lifecycle
import AppKit
import OSLog

final class WinShotManager {
    private static let thumbnailHeight: CGFloat = 200

    private var snapshots: [CGDirectDisplayID: [WinShotSnapshot]] = [:]

    // MARK: - Snapshot Access

    /// Get all snapshots for a screen, ordered by creation time (newest first)
    func snapshots(for screenId: CGDirectDisplayID) -> [WinShotSnapshot] {
        return snapshots[screenId] ?? []
    }

    /// Find a snapshot by its unique ID
    func snapshot(withId id: UUID) -> WinShotSnapshot? {
        for screenSnapshots in snapshots.values {
            if let found = screenSnapshots.first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }

    /// Check if there are any snapshots for a screen
    func hasSnapshots(for screenId: CGDirectDisplayID) -> Bool {
        guard let screenSnapshots = snapshots[screenId] else { return false }
        return !screenSnapshots.isEmpty
    }

    // MARK: - Snapshot Creation

    /// Creates a snapshot for the given screen if eligible
    /// Returns the created snapshot, or nil if creation failed or was skipped
    func createSnapshot(
        screenId: CGDirectDisplayID,
        zoneController: ZoneController,
        windowController: WindowController,
        screenDescriptor: ScreenDescriptor,
        floatingZoneOccupant: ManagedWindow?,
        rememberedStickyResizeSizesByWindowId: [Int: CGSize],
        activeWindowId: Int?,
        reason: String
    ) -> WinShotSnapshot? {
        // Collect zone data
        let zones = zoneController.allZones
        let zoneCount = zones.count

        var zoneFrames: [Int: CGRect] = [:]
        var zoneAssignments: [Int: WindowIdentity] = [:]
        var windowFrames: [Int: CGRect] = [:]

        for zone in zones {
            zoneFrames[zone.index] = zone.frame

            if let windowId = zone.occupantWindowId,
               let managed = windowController.window(withId: windowId) {
                zoneAssignments[zone.index] = WindowIdentity.make(from: managed)
                // Capture the window's actual frame in screen coordinates for potential future use.
                let frame = windowController.actualFrameInScreenCoordinates(for: managed, on: screenDescriptor)
                windowFrames[zone.index] = frame
            }
        }

        // Get floating zone occupant identity and frame
        let floatingIdentity: WindowIdentity?
        let floatingFrame: CGRect?
        if let floatingOccupant = floatingZoneOccupant {
            floatingIdentity = WindowIdentity.make(from: floatingOccupant)
            // actualFrameInScreenCoordinates can return .zero on AX read failure; treat as no frame.
            let frame = windowController.actualFrameInScreenCoordinates(for: floatingOccupant, on: screenDescriptor)
            floatingFrame = frame == .zero ? nil : frame
        } else {
            floatingIdentity = nil
            floatingFrame = nil
        }

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
        // Reuse the replaced snapshot's ID for a same-occupancy capture, so identity stays stable across
        // refreshes — e.g. a silent background re-capture won't invalidate an ID an open chooser is
        // currently displaying.
        let replacedSnapshotId = findSnapshotWithSameOccupancySignature(occupancySignature, on: screenId)
        if let replacedSnapshotId {
            Logger.debug("WinShot: Replacing existing snapshot \(replacedSnapshotId) with same occupancy signature")
            deleteSnapshot(replacedSnapshotId)
        }

        // Capture screenshot
        let thumbnail = captureScreenThumbnail(screenId: screenId)

        let rememberedTiledWindowSizesByZoneIndex = WinShotStickyResizeSnapshotMapping.snapshotSizesByZoneIndex(
            zoneAssignments: zoneAssignments,
            rememberedSizesByWindowId: rememberedStickyResizeSizesByWindowId
        )

        // Create snapshot
        let snapshot = WinShotSnapshot(
            id: replacedSnapshotId ?? UUID(),
            screenId: screenId,
            createdAt: Date(),
            zoneCount: zoneCount,
            zoneFrames: zoneFrames,
            windowFrames: windowFrames,
            rememberedTiledWindowSizesByZoneIndex: rememberedTiledWindowSizesByZoneIndex,
            zoneAssignments: zoneAssignments,
            floatingZoneOccupant: floatingIdentity,
            floatingZoneFrame: floatingFrame,
            activeWindowId: activeWindowId,
            thumbnail: thumbnail
        )

        // Store snapshot
        addSnapshot(snapshot, for: screenId)

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
        for (screenId, screenSnapshots) in snapshots {
            if let index = screenSnapshots.firstIndex(where: { $0.id == id }) {
                snapshots[screenId]?.remove(at: index)
                Logger.debug("WinShot: Deleted snapshot \(id) from \(ScreenContextStore.logDescription(for: screenId))")
                return
            }
        }
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

    // MARK: - Private Helpers

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

    private func captureScreenThumbnail(screenId: CGDirectDisplayID) -> NSImage? {
        let signpostState = ZonogySignposts.pointsOfInterest.beginInterval(
            "WinShotCaptureThumbnail",
            "screenId=\(screenId)"
        )
        defer {
            ZonogySignposts.pointsOfInterest.endInterval("WinShotCaptureThumbnail", signpostState)
        }

        guard let cgImage = CGDisplayCreateImage(screenId) else {
            Logger.debug("WinShot: Failed to capture \(ScreenContextStore.logDescription(for: screenId))")
            return nil
        }

        let fullSize = NSSize(width: cgImage.width, height: cgImage.height)
        let fullImage = NSImage(cgImage: cgImage, size: fullSize)

        // Scale down for memory efficiency
        let scale = Self.thumbnailHeight / CGFloat(cgImage.height)
        let targetWidth = CGFloat(cgImage.width) * scale
        let targetSize = NSSize(width: targetWidth, height: Self.thumbnailHeight)

        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        fullImage.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: fullSize),
            operation: .copy,
            fraction: 1.0
        )
        thumbnail.unlockFocus()

        return thumbnail
    }
}
