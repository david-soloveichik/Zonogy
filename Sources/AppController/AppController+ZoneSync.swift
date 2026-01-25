import Foundation
import AppKit
import ApplicationServices

/// Zone synchronization: keeping windows, placeholders, and layout model in lockstep.
extension AppController {

    // MARK: - Synchronization

    /// Sync all windows to their zones and keep the internal layout model,
    /// real windows, placeholders, and UI indicators in lockstep.
    ///
    /// High‑level flow:
    /// 1. Coalesce concurrent sync requests so at most one sync runs at a time.
    /// 2. Prune any external windows that the OS reports as destroyed and
    ///    remove them from any zones that still reference them.
    /// 3. For every screen/zone, position the real window (if any) into its
    ///    zone frame (respecting margins and ActiveFit reveal mode), and
    ///    record which windows were actively assigned this pass.
    /// 4. Ask `PlaceholderCoordinator` to align placeholder windows with all
    ///    empty zones (except those that are suppressed or excluded), reusing
    ///    or creating placeholder windows as needed and hiding obsolete ones.
    /// 5. Clear stale zone assignments for any non‑placeholder window that was
    ///    not assigned this pass and is not in the temporary floating zone.
    /// 6. Refresh targeted zone state, temporary‑zone targeting, and visual
    ///    indicators so the UI matches the new layout.
    internal func syncWindowsToZones(recentlyPlacedInTempZone: Int? = nil) {
        let tempZoneExclusion = recentlyPlacedInTempZone

        // Ensure only one sync runs at a time. If a sync is already underway,
        // just record that another pass is needed; the deferred block below
        // will run a follow‑up sync when safe.
        if isSyncingWindows {
            pendingSync = true
            if let recentlyPlacedInTempZone {
                pendingSyncRecentlyPlacedInTempZone = recentlyPlacedInTempZone
            }
            return
        }
        isSyncingWindows = true
        defer {
            isSyncingWindows = false
            if pendingSync {
                pendingSync = false
                let pendingTempZoneExclusion = pendingSyncRecentlyPlacedInTempZone
                pendingSyncRecentlyPlacedInTempZone = nil
                syncWindowsToZones(recentlyPlacedInTempZone: pendingTempZoneExclusion)
            }
        }

        Logger.debug("Syncing windows to zones")

        // Phase 1: prune any windows that have been destroyed according to the
        // underlying Accessibility / CGWindow APIs, and remove them from zones
        // so no layout continues to reference dead windows.
        let prunedWindowIds = windowController.pruneDestroyedExternalWindows()
        if !prunedWindowIds.isEmpty {
            handleDestroyedWindows(
                prunedWindowIds,
                reason: "sync-prune-destroyed",
                retarget: true,
                shouldSync: false,
                shouldRefreshWinShotChooser: true
            )
        }

        // Tracks all non‑placeholder windows that end up with a valid zone
        // assignment in this pass. Anything not in this set (and not in the
        // temporary zone) will be detached from the tiling model at the end.
        var assignedWindowIds = Set<Int>()

        // Phase 2: walk every screen and zone, and for each zone that already
        // has a real window, move/resize that window into the zone's content
        // frame (with margins) unless ActiveFit says to preserve reveal mode.
        for screenId in screenOrder {
            guard let context = screenContexts[screenId],
                  let descriptor = descriptor(for: screenId) else {
                continue
            }
            let controller = context.zoneController

            for zone in controller.allZones {
                if let windowId = zone.occupantWindowId,
                   let managed = windowController.window(withId: windowId) {
                    let zoneKey = ZoneKey(screenId: screenId, index: zone.index)
                    if activeFitShouldSkipSync(for: zoneKey, windowId: windowId) {
                        // For ActiveFit reveal mode, keep the window in its
                        // current reveal frame but still treat it as assigned
                        // to this zone for bookkeeping and targeting.
                        Logger.debug("Sync skipping zone \(zone.index) on \(context.descriptor.localizedName) [screen \(screenContextStore.loggingIndex(for: screenId))] due to active ActiveFit window \(windowId)")
                        setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
                        assignedWindowIds.insert(windowId)
                        continue
                    }
                    // Normal case: compute the zone's content frame (respecting
                    // the 8px/4px margins) and move the window into it.
                    let displayFrame = frameWithMargin(for: zone, in: controller)
                    windowController.moveWindow(managed, to: displayFrame, on: descriptor)
                    // If the user had manually resized this window, once we
                    // snap it back to the zone we can clear the detached flag.
                    manualResizeDetachedWindowIds.remove(windowId)
                    setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
                    assignedWindowIds.insert(windowId)
                }
            }
        }

        // Phase 3: sync placeholder windows so every empty zone has a matching placeholder
        // (unless explicitly suppressed for this pass). PlaceholderCoordinator owns and
        // tracks placeholder windows internally.
        placeholderCoordinator.syncPlaceholders(
            screenOrder: screenOrder,
            contextProvider: { screenId in
                guard let context = self.screenContexts[screenId],
                      let descriptor = self.descriptor(for: screenId) else {
                    return nil
                }
                let zoneController = context.zoneController
                return PlaceholderCoordinatorScreenContext(
                    descriptor: descriptor,
                    zoneController: zoneController,
                    displayFrameForZone: { zone in
                        self.frameWithMargin(for: zone, in: zoneController)
                    }
                )
            },
            shouldSuppressPlaceholder: { [weak self] key in
                guard let self = self else { return false }
                if self.isScreenPausedForFullScreen(key.screenId) {
                    return true
                }
                // UnderCovers suppresses the single-zone placeholder on that screen while active.
                return self.isUnderCoversActive(on: key.screenId) && key.index == 1
            }
        )

        // Placeholder windows are now managed separately by PlaceholderCoordinator
        let placeholderCount = placeholderCoordinator.activePlaceholderCount

        // Calculate zone occupancy for logging/diagnostics.
        var occupiedZones = 0
        var emptyZones = 0
        for context in screenContexts.values {
            for zone in context.zoneController.allZones {
                if zone.isEmpty {
                    emptyZones += 1
                } else {
                    occupiedZones += 1
                }
            }
        }

        Logger.debug("Sync complete: assigned \(assignedWindowIds.count) window(s), placeholders \(placeholderCount), zones: \(occupiedZones) occupied, \(emptyZones) empty")

        // Phase 4: clean up stale assignments. Any window that was *not*
        // assigned to a tiled zone in this pass and is *not* parked in the
        // temporary floating zone should no longer be treated as zoned.
        for window in windowController.allWindows {
            if assignedWindowIds.contains(window.windowId) {
                continue
            }
            if isWindowInTemporaryZone(window.windowId) {
                continue
            }
            clearManagedWindowZone(window)
        }

        // Phase 5: promote temporary zone occupants into newly-emptied tiling zones.
        // Spec: "When a tiling zone on a screen becomes empty and that screen has
        // a temporary-zone occupant, promote the temporary window into the emptied zone."
        func snapshotZoneKeys() -> (known: Set<ZoneKey>, empty: Set<ZoneKey>) {
            var known = Set<ZoneKey>()
            var empty = Set<ZoneKey>()

            for screenId in screenOrder {
                guard let context = screenContexts[screenId] else {
                    continue
                }
                for zone in context.zoneController.allZones {
                    let key = ZoneKey(screenId: screenId, index: zone.index)
                    known.insert(key)
                    if isZoneEffectivelyEmpty(zone) {
                        empty.insert(key)
                    }
                }
            }

            return (known, empty)
        }

        let prePromotionSnapshot = snapshotZoneKeys()
        let newlyEmptiedZones = prePromotionSnapshot.empty
            .intersection(lastSyncKnownZoneKeys)
            .subtracting(lastSyncEmptyZoneKeys)

        promoteTemporaryZoneOccupantsIfNeeded(
            newlyEmptiedZones: newlyEmptiedZones,
            excluding: tempZoneExclusion,
            reason: "sync"
        )

        let postPromotionSnapshot = snapshotZoneKeys()
        lastSyncKnownZoneKeys = postPromotionSnapshot.known
        lastSyncEmptyZoneKeys = postPromotionSnapshot.empty

        // Phase 6: ensure targeting and indicators are consistent with the new
        // layout — pick a valid targeted zone if needed and refresh all on‑screen adornments.
        targetedZoneManager.ensureTargetedZone(reason: "sync")
        refreshIndicators()
        refreshResizeHandles()
        launcherController.repositionIfNeeded()
    }

    func shouldDeferPlacementForNewWindow(_ managed: ManagedWindow, targetedZoneKey: ZoneKey?) -> Bool {
        // Chrome merges kill the dragged window until the drop completes; avoid evicting the sibling.
        guard let targetedZoneKey = targetedZoneKey else {
            return false
        }
        let pid = managed.backing.pid
        guard MouseButtons.isLeftMouseButtonDown() else {
            return false
        }
        guard let context = screenContexts[targetedZoneKey.screenId],
              let zone = context.zoneController.zone(at: targetedZoneKey.index),
              let occupantId = zone.occupantWindowId,
              occupantId != managed.windowId,
              let occupant = windowController.window(withId: occupantId),
              occupant.backing.pid == pid else {
            return false
        }
        return true
    }

    /// Compute the frame used to render content inside a zone, honoring the spec margin
    internal func frameWithMargin(for zone: Zone, in controller: ZoneController) -> CGRect {
        let margins = zoneMargins(for: zone, in: controller)

        var left = margins.left
        var right = margins.right
        var top = margins.top
        var bottom = margins.bottom

        var frame = zone.frame.standardized

        let horizontalTotal = left + right
        if horizontalTotal > frame.width && frame.width > 0 {
            let scale = frame.width / horizontalTotal
            left *= scale
            right *= scale
        }

        let verticalTotal = top + bottom
        if verticalTotal > frame.height && frame.height > 0 {
            let scale = frame.height / verticalTotal
            top *= scale
            bottom *= scale
        }

        frame.origin.x += left
        frame.origin.y += top
        frame.size.width = max(0, frame.size.width - (left + right))
        frame.size.height = max(0, frame.size.height - (top + bottom))

        return frame
    }

    private func zoneMargins(for zone: Zone, in controller: ZoneController) -> ZoneEdgeMargins {
        let frame = zone.frame.standardized
        let bounds = controller.layoutBounds.standardized
        let neighbors = controller.allZones.filter { $0 !== zone }

        let fullMargin = zoneMargin
        let sharedMargin = zoneMargin / 2
        let tolerance = edgeAlignmentTolerance

        func verticalOverlap(with other: CGRect) -> CGFloat {
            let standardized = other.standardized
            return min(frame.maxY, standardized.maxY) - max(frame.minY, standardized.minY)
        }

        func horizontalOverlap(with other: CGRect) -> CGFloat {
            let standardized = other.standardized
            return min(frame.maxX, standardized.maxX) - max(frame.minX, standardized.minX)
        }

        let hasLeftNeighbor = neighbors.contains {
            abs($0.frame.standardized.maxX - frame.minX) <= tolerance && verticalOverlap(with: $0.frame) > 0
        }
        let hasRightNeighbor = neighbors.contains {
            abs($0.frame.standardized.minX - frame.maxX) <= tolerance && verticalOverlap(with: $0.frame) > 0
        }
        let hasTopNeighbor = neighbors.contains {
            abs($0.frame.standardized.maxY - frame.minY) <= tolerance && horizontalOverlap(with: $0.frame) > 0
        }
        let hasBottomNeighbor = neighbors.contains {
            abs($0.frame.standardized.minY - frame.maxY) <= tolerance && horizontalOverlap(with: $0.frame) > 0
        }

        let leftMargin: CGFloat
        if abs(frame.minX - bounds.minX) <= tolerance {
            leftMargin = fullMargin
        } else if hasLeftNeighbor {
            leftMargin = sharedMargin
        } else {
            leftMargin = fullMargin
        }

        let rightMargin: CGFloat
        if abs(frame.maxX - bounds.maxX) <= tolerance {
            rightMargin = fullMargin
        } else if hasRightNeighbor {
            rightMargin = sharedMargin
        } else {
            rightMargin = fullMargin
        }

        let topMargin: CGFloat
        if abs(frame.minY - bounds.minY) <= tolerance {
            topMargin = fullMargin
        } else if hasTopNeighbor {
            topMargin = sharedMargin
        } else {
            topMargin = fullMargin
        }

        let bottomMargin: CGFloat
        if abs(frame.maxY - bounds.maxY) <= tolerance {
            bottomMargin = fullMargin
        } else if hasBottomNeighbor {
            bottomMargin = sharedMargin
        } else {
            bottomMargin = fullMargin
        }

        return ZoneEdgeMargins(
            top: max(0, topMargin),
            left: max(0, leftMargin),
            bottom: max(0, bottomMargin),
            right: max(0, rightMargin)
        )
    }
}
