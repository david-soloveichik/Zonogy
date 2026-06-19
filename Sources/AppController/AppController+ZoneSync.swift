import Foundation
import AppKit
import ApplicationServices
import OSLog

/// Zone synchronization: keeping windows, placeholders, and layout model in lockstep.
extension AppController {
    private enum ZoneSyncMode {
        case full
        case liveResize(screenId: CGDirectDisplayID)

        var isLiveResize: Bool {
            switch self {
            case .full:
                return false
            case .liveResize:
                return true
            }
        }

        func debugLabel(in appController: AppController) -> String {
            switch self {
            case .full:
                return "full"
            case .liveResize(let screenId):
                return "live-resize screen \(appController.screenContextStore.logDescription(for: screenId))"
            }
        }
    }

    // MARK: - Synchronization

    /// Sync all windows to their zones and keep the internal layout model,
    /// real windows, placeholders, and UI indicators in lockstep.
    ///
    /// High‑level flow:
    /// 1. Coalesce concurrent sync requests so at most one sync runs at a time.
    /// 2. Prune any external windows that the OS reports as destroyed and
    ///    remove them from any zones that still reference them.
    /// 3. Reconcile zone occupancy so no zone references a missing managed window.
    /// 4. For every screen/zone, position the real window (if any) into its
    ///    zone frame (respecting margins and ActiveFit reveal mode), except
    ///    windows marked by placement bookkeeping for a one-pass geometry
    ///    skip, and record which windows were actively assigned this pass.
    /// 5. Ask `PlaceholderCoordinator` to align placeholder windows with all
    ///    empty zones (except those that are suppressed or excluded), reusing
    ///    or creating placeholder windows as needed and hiding obsolete ones.
    /// 6. Clear stale zone assignments for any non‑placeholder window that was
    ///    not assigned this pass and is not in the floating zone.
    /// 7. Promote floating-zone occupants into newly emptied tiling zones
    ///    when policy conditions are met.
    /// 8. Refresh targeted zone state, floating-zone targeting, and visual
    ///    indicators so the UI matches the new layout.
    internal func syncWindowsToZones(recentlyPlacedInFloatingZone: Int? = nil) {
        runZoneSync(
            mode: .full,
            recentlyPlacedInFloatingZone: recentlyPlacedInFloatingZone,
        )
    }

    /// Fast sync path for live zone-resize dragging.
    /// Assumes occupancy/topology are stable and focuses on applying updated geometry.
    internal func syncWindowsToZonesForLiveResize(screenId: CGDirectDisplayID) {
        runZoneSync(
            mode: .liveResize(screenId: screenId),
            recentlyPlacedInFloatingZone: nil,
        )
    }

    private func nextCoalescedZoneSyncMode(pendingFloatingZoneExclusion: Int?) -> ZoneSyncMode {
        if pendingFloatingZoneExclusion != nil {
            return .full
        }
        if zoneResizeDragInProgress, let dragScreenId = zoneResizeDragScreenId {
            return .liveResize(screenId: dragScreenId)
        }
        return .full
    }

    private func runZoneSync(mode: ZoneSyncMode, recentlyPlacedInFloatingZone: Int?) {
        let floatingZoneExclusion = recentlyPlacedInFloatingZone
        let isLiveResizeSync = mode.isLiveResize

        // Ensure only one sync runs at a time. If a sync is already underway,
        // just record that another pass is needed; the deferred block below
        // will run a follow‑up sync when safe.
        if isSyncingWindows {
            pendingSync = true
            if let recentlyPlacedInFloatingZone {
                pendingSyncRecentlyPlacedInFloatingZone = recentlyPlacedInFloatingZone
            }
            return
        }
        // One-pass geometry-skip marks are only relevant for full syncs.
        // Consume the set up front so each marked window is skipped at most once.
        let skipGeometryWindowIds: Set<Int>
        if isLiveResizeSync {
            skipGeometryWindowIds = []
        } else {
            pendingSyncSkipGeometryCleanupWorkItem?.cancel()
            pendingSyncSkipGeometryCleanupWorkItem = nil
            skipGeometryWindowIds = pendingSyncSkipGeometryWindowIds
            pendingSyncSkipGeometryWindowIds.removeAll()
        }
        isSyncingWindows = true
        defer {
            isSyncingWindows = false
            if pendingSync {
                pendingSync = false
                let pendingFloatingZoneExclusion = pendingSyncRecentlyPlacedInFloatingZone
                pendingSyncRecentlyPlacedInFloatingZone = nil
                let nextMode = nextCoalescedZoneSyncMode(pendingFloatingZoneExclusion: pendingFloatingZoneExclusion)
                runZoneSync(mode: nextMode, recentlyPlacedInFloatingZone: pendingFloatingZoneExclusion)
            }
        }

        let signpostState = ZonogySignposts.pointsOfInterest.beginInterval(
            "ZoneSync",
            "mode=\(mode.debugLabel(in: self), privacy: .public) floatingExclusion=\(floatingZoneExclusion ?? -1)"
        )
        defer {
            ZonogySignposts.pointsOfInterest.endInterval("ZoneSync", signpostState)
        }

        Logger.debug("Syncing windows to zones (\(mode.debugLabel(in: self)))")

        // Phase 1: prune any windows that have been destroyed according to the
        // underlying Accessibility / CGWindow APIs, and remove them from zones
        // so no layout continues to reference dead windows.
        if !isLiveResizeSync {
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
        }

        // Phase 2: clear stale zone occupancy. Even if a destroyed window was
        // pruned earlier, recapture/sync interleavings can leave a zone with a
        // dead occupant ID. Reconcile occupancy against the live registry.
        if !isLiveResizeSync {
            let liveWindowIds = Set(windowController.allWindows.map { $0.windowId })
            var zoneSnapshots: [ZoneOccupancyReconciler.ZoneOccupantSnapshot] = []
            for screenId in screenOrder {
                guard let context = screenContexts[screenId] else {
                    continue
                }
                for zone in context.zoneController.allZones {
                    zoneSnapshots.append(
                        ZoneOccupancyReconciler.ZoneOccupantSnapshot(
                            key: ZoneKey(screenId: screenId, index: zone.index),
                            occupantWindowId: zone.occupantWindowId
                        )
                    )
                }
            }
            let staleOccupants = ZoneOccupancyReconciler.staleOccupants(
                from: zoneSnapshots,
                liveWindowIds: liveWindowIds
            )
            var firstClearedZoneKey: ZoneKey?
            for stale in staleOccupants {
                guard let context = screenContexts[stale.key.screenId],
                      let zone = context.zoneController.zone(at: stale.key.index),
                      zone.occupantWindowId == stale.windowId else {
                    continue
                }
                Logger.debug(
                    "Sync clearing stale zone occupant \(stale.windowId) from zone \(stale.key.index) " +
                    "on \(context.descriptor.localizedName) [screen \(screenContextStore.loggingIndex(for: stale.key.screenId))]"
                )
                context.zoneController.removeWindow(windowId: stale.windowId)
                if firstClearedZoneKey == nil {
                    firstClearedZoneKey = stale.key
                }
            }
            if let firstClearedZoneKey {
                targetedZoneManager.setTargetedZone(firstClearedZoneKey, reason: "sync-cleared-stale-occupant")
                autoShowLauncherIfEmptyTargetedTiledZone()
            }
        }

        // Tracks all non‑placeholder windows that end up with a valid zone
        // assignment in this pass. Anything not in this set (and not in the
        // floating zone) will be detached from the tiling model at the end.
        var assignedWindowIds = Set<Int>()

        // Phase 3: walk every screen and zone, and for each zone that already
        // has a real window, move/resize that window into the zone's content
        // frame (with margins) unless ActiveFit says to preserve reveal mode.
        // In live-resize mode, only the dragged screen is visited.
        let phase3ScreenOrder: [CGDirectDisplayID]
        switch mode {
        case .full:
            phase3ScreenOrder = screenOrder
        case .liveResize(let screenId):
            phase3ScreenOrder = [screenId]
        }
        for screenId in phase3ScreenOrder {
            guard let context = screenContexts[screenId],
                  let descriptor = descriptor(for: screenId) else {
                continue
            }
            let controller = context.zoneController

            for zone in controller.allZones {
                if let windowId = zone.occupantWindowId,
                   let managed = windowController.window(withId: windowId) {
                    let zoneKey = ZoneKey(screenId: screenId, index: zone.index)
                    if !isLiveResizeSync,
                       skipGeometryWindowIds.contains(windowId) {
                        Logger.debug(
                            "Sync skipping geometry apply for window \(windowId) in zone \(zone.index) " +
                                "on \(context.descriptor.localizedName) [screen \(screenContextStore.loggingIndex(for: screenId))] " +
                                "due to recent placement bookkeeping"
                        )
                        manualResizeDetachedWindowIds.remove(windowId)
                        setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
                        assignedWindowIds.insert(windowId)
                        continue
                    }
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
                    // the 8px/4px margins), or the remembered Sticky Resize frame
                    // for the currently active window, and move the window there.
                    let frameResolution = stickyResizeFrameResolution(
                        for: managed,
                        zone: zone,
                        controller: controller
                    )
                    let displayFrame = frameResolution.frame
                    if isLiveResizeSync {
                        // Fast path: dispatch AX writes to a background queue,
                        // skip unchanged attributes based on previous target.
                        let previousFrame = liveResizePreviousFrames[windowId]
                        let effectiveFrame = windowController.moveWindowForLiveResize(
                            managed,
                            targetScreenFrame: displayFrame,
                            previousTargetScreenFrame: previousFrame,
                            screen: descriptor
                        )
                        liveResizePreviousFrames[windowId] = effectiveFrame
                    } else {
                        windowController.moveWindow(managed, to: displayFrame, on: descriptor)
                    }
                    if frameResolution.usesRememberedSize {
                        manualResizeDetachedWindowIds.insert(windowId)
                    } else {
                        // If the user had manually resized this window, once we
                        // snap it back to the zone we can clear the detached flag.
                        manualResizeDetachedWindowIds.remove(windowId)
                    }
                    setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
                    assignedWindowIds.insert(windowId)
                }
            }
        }

        // Flush accumulated live-resize AX writes as a single batch.
        if isLiveResizeSync {
            windowController.flushLiveResizeWrites()
        }

        // Phase 4: sync placeholder windows so every empty zone has a matching placeholder
        // (unless explicitly suppressed for this pass). PlaceholderCoordinator owns and
        // tracks placeholder windows internally.
        let placeholderContextProvider: (CGDirectDisplayID) -> PlaceholderCoordinatorScreenContext? = { screenId in
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
        }
        let shouldSuppressPlaceholder: (ZoneKey) -> Bool = { key in
            if self.isScreenPausedForFullScreen(key.screenId) {
                return true
            }
            // UnderCovers suppresses the single-zone placeholder on that screen while active.
            return self.isUnderCoversActive(on: key.screenId) && key.index == 1
        }
        switch mode {
        case .full:
            placeholderCoordinator.syncPlaceholders(
                screenOrder: screenOrder,
                contextProvider: placeholderContextProvider,
                shouldSuppressPlaceholder: shouldSuppressPlaceholder
            )
        case .liveResize(let screenId):
            placeholderCoordinator.syncPlaceholders(
                forScreens: [screenId],
                contextProvider: placeholderContextProvider,
                shouldSuppressPlaceholder: shouldSuppressPlaceholder
            )
        }

        // Placeholder windows are now managed separately by PlaceholderCoordinator
        let placeholderCount = placeholderCoordinator.activePlaceholderCount

        // Calculate zone occupancy for logging/diagnostics.
        if isLiveResizeSync {
            Logger.debug(
                "Sync complete (\(mode.debugLabel(in: self))): assigned \(assignedWindowIds.count) window(s), placeholders \(placeholderCount)"
            )
        } else {
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
        }

        // Phase 5: clean up stale assignments. Any window that was *not*
        // assigned to a tiled zone in this pass and is *not* parked in the
        // floating zone should no longer be treated as zoned.
        if !isLiveResizeSync {
            for window in windowController.allWindows {
                if assignedWindowIds.contains(window.windowId) {
                    continue
                }
                if isWindowInFloatingZone(window.windowId) {
                    continue
                }
                clearManagedWindowZone(window)
            }
        }

        // Phase 6: promote floating zone occupants into newly-emptied tiling zones.
        // Spec: "When a tiling zone on a screen becomes empty and that screen has
        // a floating-zone occupant, promote the floating window into the emptied zone."
        if !isLiveResizeSync {
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

            promoteFloatingZoneOccupantsIfNeeded(
                newlyEmptiedZones: newlyEmptiedZones,
                excluding: floatingZoneExclusion,
                reason: "sync"
            )

            let postPromotionSnapshot = snapshotZoneKeys()
            lastSyncKnownZoneKeys = postPromotionSnapshot.known
            lastSyncEmptyZoneKeys = postPromotionSnapshot.empty
        }

        // Phase 7: ensure targeting and indicators are consistent with the new
        // layout — pick a valid targeted zone if needed and refresh all on‑screen adornments.
        if case .liveResize(let screenId) = mode {
            refreshZoneIndicators(forScreens: Set([screenId]))
            // Keep the occupied-zone target border tracking the live geometry, just as Phase 4 above
            // repositions placeholders for empty zones; otherwise the border lags behind the window.
            refreshOccupiedZoneTargetBorder()
            if launcherController.isActive, targetedScreenId() == screenId {
                launcherController.repositionIfNeeded()
            }
            return
        }
        targetedZoneManager.ensureTargetedZone(reason: "sync")
        refreshIndicators()
        refreshResizeHandles()
        launcherController.repositionIfNeeded()
        // Refresh Launcher's zone-derived row data; it's snapshotted at open time
        // and would otherwise stay stale after the optimistic auto-show.
        launcherController.refreshZoneDerivedDataIfActive()

        // Occupancy is now settled for this pass: feed it to the WinShot auto-save settle timer.
        evaluateWinShotOccupancyAutoSave()
    }

    func requestSync() {
        syncWindowsToZones()
    }

    func markWindowForNextSyncGeometrySkip(windowId: Int) {
        pendingSyncSkipGeometryWindowIds.insert(windowId)
        schedulePendingSyncGeometrySkipCleanupIfNeeded()
    }

    /// Geometry-skip marks are intended for the placement operation's immediate follow-up sync.
    /// If no such sync runs before the next runloop turn, clear the marks to avoid
    /// unrelated later syncs accidentally consuming stale skip state.
    private func schedulePendingSyncGeometrySkipCleanupIfNeeded() {
        guard pendingSyncSkipGeometryCleanupWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSyncSkipGeometryCleanupWorkItem = nil
            self.pendingSyncSkipGeometryWindowIds.removeAll()
        }
        pendingSyncSkipGeometryCleanupWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func decideNewWindowPlacement(
        _ managed: ManagedWindow,
        targetedZoneKey: ZoneKey?,
        targetedScreenId: CGDirectDisplayID?
    ) -> NewWindowPlacementDecision {
        let originScreenId = detectScreenId(for: managed)
        let originPaused = originScreenId.map { isScreenPausedForFullScreen($0) } ?? false
        let originNative = (originScreenId.map { isNativeFullScreenPause(screenId: $0) }) ?? false
        let targetPaused = targetedScreenId.map { isScreenPausedForFullScreen($0) } ?? false

        let fullScreenOutcome = FullScreenPlacementPolicy.decide(
            originScreenId: originScreenId,
            originIsPausedForFullScreen: originPaused,
            originIsNativeFullScreen: originNative,
            targetedScreenId: targetedScreenId,
            targetIsPausedForFullScreen: targetPaused
        )

        switch fullScreenOutcome {
        case .defer:
            if let originScreenId {
                let screenIndex = screenContextStore.loggingIndex(for: originScreenId)
                Logger.debug(
                    "Deferring placement for window \(managed.windowId) because screen \(screenIndex) is paused for full-screen"
                )
            }
            return .defer
        case .placeAndRestoreNativeFullScreenSpace(let origin):
            let originIndex = screenContextStore.loggingIndex(for: origin)
            if let targetedScreenId {
                let targetIndex = screenContextStore.loggingIndex(for: targetedScreenId)
                Logger.debug(
                    "Partial-pause placement: window \(managed.windowId) opened on native-full-screen screen \(originIndex); " +
                        "routing to targeted zone on screen \(targetIndex)"
                )
            }
            return .placeAndRestoreNativeFullScreenSpace(originScreenId: origin)
        case .proceedNormally:
            break
        }

        // Drag tear-out: Chrome merges kill the dragged window until the drop completes;
        // avoid evicting the sibling that's still in the targeted tiled zone.
        guard let targetedZoneKey = targetedZoneKey else {
            return .placeNormally
        }
        let pid = managed.backing.pid
        guard MouseButtons.isLeftMouseButtonDown() else {
            return .placeNormally
        }
        guard let context = screenContexts[targetedZoneKey.screenId],
              let zone = context.zoneController.zone(at: targetedZoneKey.index),
              let occupantId = zone.occupantWindowId,
              occupantId != managed.windowId,
              let occupant = windowController.window(withId: occupantId),
              occupant.backing.pid == pid else {
            return .placeNormally
        }
        Logger.debug(
            "Deferring placement for window \(managed.windowId) because of active drag tear-out " +
                "targeting zone \(targetedZoneKey.index) on screen \(screenContextStore.loggingIndex(for: targetedZoneKey.screenId))"
        )
        return .defer
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

        frame.origin.x = (frame.origin.x + left).rounded()
        frame.origin.y = (frame.origin.y + top).rounded()
        frame.size.width = max(0, (frame.size.width - (left + right)).rounded())
        frame.size.height = max(0, (frame.size.height - (top + bottom)).rounded())

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
