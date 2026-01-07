import Foundation
import AppKit
import ApplicationServices

/// Zone lifecycle operations: zone/window commands, placement, sync, and indicator refresh.
extension AppController {
    func addZone() {
        let screenId = activeScreenId()
        _ = addZone(on: screenId, announce: true, promoteTemporaryOccupant: true)
    }

    @discardableResult
    internal func addZone(
        on screenId: CGDirectDisplayID,
        announce: Bool = true,
        promoteTemporaryOccupant: Bool = true
    ) -> Zone? {
        // Special-case: if this screen is in UnderCovers and has a single empty zone 1,
        // treat the first "add zone" invocation as exiting UnderCovers without changing zone count.
        if let context = screenContexts[screenId] {
            let zones = context.zoneController.allZones
            if isUnderCoversActive(on: screenId),
               zones.count == 1,
               let zone = zones.first,
               zone.index == 1,
               zone.isEmpty {
                Logger.debug("Add zone invoked while UnderCovers active on screen \(screenContextStore.loggingIndex(for: screenId)); exiting UnderCovers without adding a new zone")
                endUnderCovers(on: screenId, reason: "add-zone-exit-undercovers", recreatePlaceholders: true)
                return zone
            }
        }

        // Any shortcut or command adding a zone to this screen should exit UnderCovers otherwise.
        endUnderCovers(on: screenId, reason: "add-zone", recreatePlaceholders: false)

        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            if announce {
                print("Failed to add zone (max 3 zones)")
            }
            return nil
        }
        // Zone topology has changed; cancel any in-flight accessibility frame retries
        // so they do not apply stale geometry.
        windowController.cancelAllAccessibilityFrameRetries()
        if promoteTemporaryOccupant {
            promoteTemporaryZoneOccupantIfNeeded(on: screenId, newZone: newZone)
        }
        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: "zone-added")
        let newZoneKey = zoneKey(for: screenId, index: newZone.index)
        if shouldRetarget(to: newZoneKey) {
            targetedZoneManager.setTargetedZone(newZoneKey, reason: "zone-added")
            // If we targeted a zone that's already filled (e.g., from temporary zone promotion),
            // retarget per spec: "Whenever the targeted tiling zone is filled..."
            if targetingMode == .independentOfFocus,
               !targetedZoneManager.isZoneEmpty(newZoneKey) {
                targetedZoneManager.retargetAfterFillingZone(newZoneKey, reason: "zone-added-filled")
            }
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "zone-added")
        }
        if announce {
            print("Added zone \(newZone.index) on \(context.descriptor.localizedName)")
        }
        autoShowLauncherIfEmptyTargetedTiledZone()
        return newZone
    }

    private func promoteTemporaryZoneOccupantIfNeeded(on screenId: CGDirectDisplayID, newZone: Zone) {
        guard newZone.isEmpty,
              let occupant = temporaryZoneOccupant(on: screenId),
              !occupant.isPlaceholder,
              occupant.zoneIndex == nil else {
            return
        }

        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Promoting temporary zone window \(occupant.windowId) into new zone \(newZone.index) on screen \(screenIndex)")
        windowPlacementManager.placeWindow(occupant, into: ZoneKey(screenId: screenId, index: newZone.index), reason: "add-zone-promote-temporary")
    }

    func removeZone(at index: Int) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard performRemoveZone(at: index, on: screenId, announce: true, context: context) != nil else {
            print("Failed to remove zone \(index)")
            return
        }
    }

    internal func performRemoveZone(
        at index: Int,
        on screenId: CGDirectDisplayID,
        announce: Bool,
        context: ScreenContext? = nil
    ) -> ZoneController.RemovalResult? {
        // Removing a zone on this screen should clear any UnderCovers state there.
        endUnderCovers(on: screenId, reason: "remove-zone", recreatePlaceholders: false)

        // Track if Launcher was active - dismissal decision happens after computing new target
        let launcherWasActive = launcherController.isActive

        let context = context ?? screenContexts[screenId]
        guard let context else {
            return nil
        }

        guard let removalResult = context.zoneController.removeZone(at: index) else {
            return nil
        }

        // Clear placeholder mappings for this screen since zones are being reindexed
        // This prevents stale mappings from causing duplicate placeholders
        placeholderCoordinator.clearMappingsForScreen(screenId)

        // Zone topology has changed; cancel any in-flight accessibility frame retries
        // so they do not apply stale geometry computed before the removal.
        windowController.cancelAllAccessibilityFrameRetries()

        let currentTarget = targetedZoneKey
        var pendingTargetedKey: ZoneKey?
        var shouldTargetTemporary = false
        if let currentTarget, currentTarget.screenId == screenId {
            if currentTarget.index == index {
                // The targeted zone is being removed, find a fallback
                if let destination = followsFocusTargetOnZoneRemoval(removedIndex: index, removedScreenId: screenId) {
                    switch destination {
                    case .tiled(let key):
                        pendingTargetedKey = key
                    case .temporary(let tempScreenId):
                        targetedZoneManager.setTemporaryTarget(on: tempScreenId, reason: "zone-removed-follows-focus")
                    }
                } else {
                    pendingTargetedKey = targetedZoneManager.fallbackTargetedZoneOnSameScreen(screenId: screenId)
                    if pendingTargetedKey == nil {
                        shouldTargetTemporary = true
                    }
                }
            } else if currentTarget.index > index {
                pendingTargetedKey = ZoneKey(screenId: screenId, index: currentTarget.index - 1)
            }
        }

        // Spec: When Launcher is open and zone is removed:
        // - If another empty tiling zone becomes targeted → keep Launcher open
        // - Otherwise → dismiss Launcher
        if launcherWasActive {
            var newTargetIsEmptyTiledZone = false

            if !shouldTargetTemporary {
                let effectiveTargetKey: ZoneKey?
                if let pending = pendingTargetedKey {
                    effectiveTargetKey = pending
                } else {
                    effectiveTargetKey = currentTarget
                }

                if let key = effectiveTargetKey {
                    newTargetIsEmptyTiledZone = targetedZoneManager.isZoneEmpty(key)
                }
            }

            if !newTargetIsEmptyTiledZone {
                launcherController.hide()
                Logger.debug("Launcher: Dismissed on zone removal (new target is not empty tiling zone)")
            }
        }

        if let pendingTargetedKey {
            targetedZoneManager.setTargetedZone(pendingTargetedKey, reason: "zone-removed")
        } else if shouldTargetTemporary {
            targetedZoneManager.setTemporaryTarget(on: screenId, reason: "zone-removed-no-empty-same-screen")
        }

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            windowPlacementManager.handleWindowAfterZoneRemoval(managed, preferredScreenId: screenId)
        }

        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: "zone-removed")

        if pendingTargetedKey == nil && !shouldTargetTemporary {
            targetedZoneManager.ensureTargetedZone(reason: "zone-removed")
        }

        if announce {
            print("Removed zone \(index) on \(context.descriptor.localizedName)")
        }

        return removalResult
    }

    func resizeZone(at index: Int, frame: CGRect) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard let zone = context.zoneController.zone(at: index) else {
            print("Zone \(index) not found on \(context.descriptor.localizedName)")
            return
        }

        guard zone.isEmpty else {
            print("Zone \(index) is occupied; minimize or close its window before resizing.")
            return
        }

        if context.zoneController.resizeZone(at: index, to: frame) {
            // Zone geometry changed; clear any pending accessibility frame retries
            // since their targets were based on the previous layout.
            windowController.cancelAllAccessibilityFrameRetries()
            syncWindowsToZones()
            if let updatedZone = context.zoneController.zone(at: index) {
                print("Resized zone \(index) on \(context.descriptor.localizedName) to \(updatedZone.frame)")
            } else {
                print("Zone \(index) resized")
            }
        } else {
            print("Failed to resize zone \(index)")
        }
    }

    // MARK: - Window Management

    func closeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        // Remove from zone
        removeWindowFromAllZones(windowId: windowId, reason: "close-command")

        // Close the window
        windowController.closeWindow(managed)

        // Sync to create placeholder if needed
        syncWindowsToZones()

        print("Closed window \(windowId)")
    }

    func minimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        let emptiedZoneKey = zoneKey(forManagedWindow: managed)

        let wasManualResizeDetached = performProgrammaticMinimizeCleanup(
            managed,
            minimizeReason: "minimize-command",
            cleanupReason: "minimize-command",
            retarget: true
        )
        syncWindowsToZones()
        scheduleMinimizeVerification(
            windowId: managed.windowId,
            emptiedZoneKey: emptiedZoneKey,
            minimizeReason: "minimize-command",
            cleanupReason: "minimize-command",
            wasManualResizeDetached: wasManualResizeDetached
        )

        print("Minimized window \(windowId)")
    }

    func unminimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        windowController.unminimizeWindow(managed)

        // Place the window using normal placement logic
        windowPlacementManager.placeNewWindow(managed)

        print("Unminimized window \(windowId)")
    }

    func captureFrontmostWindow() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            print("Frontmost application \(bundleId) is configured to be ignored.")
            return
        }

        guard let managed = windowController.captureFrontmostWindow() else {
            print("No frontmost window available. Make sure Accessibility permissions are granted and another app has a visible window.")
            return
        }

        if let key = zoneKey(forManagedWindow: managed),
           let context = screenContexts[key.screenId],
           let zone = context.zoneController.zone(at: key.index),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            print("Window \(managed.windowId) is already managed in zone \(key.index)")
            return
        }

        windowPlacementManager.placeNewWindow(managed)
        print("Captured window \(managed.windowId)")
    }

    func validateApplication(pid: pid_t) {
        let pruned = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "repl-command")
        if pruned.isEmpty {
            print("Validated pid \(pid): no destroyed windows detected")
        } else {
            print("Validated pid \(pid): pruned windows \(pruned)")
        }
    }

    // MARK: - Window Placement Logic




    private func indicatorFrame(for zone: Zone, controller: ZoneController, descriptor: ScreenDescriptor) -> CGRect {
        let screenBounds = descriptor.visibleScreenBounds.standardized
        let contentFrame = frameWithMargin(for: zone, in: controller).standardized
        let indicatorHeight: CGFloat = 6
        let minWidth: CGFloat = 40
        let targetWidth = max(minWidth, contentFrame.width / 3)
        let clampedWidth = min(targetWidth, contentFrame.width)

        var originX = contentFrame.midX - clampedWidth / 2
        originX = max(screenBounds.minX, min(originX, screenBounds.maxX - clampedWidth))

        let offset: CGFloat = 2
        let fallbackBottom = contentFrame.minY - offset
        var originY = fallbackBottom - indicatorHeight
        var usedGapPlacement = false

        if zone.index > 1, let previousZone = controller.zone(at: zone.index - 1) {
            let previousContentFrame = frameWithMargin(for: previousZone, in: controller).standardized
            let gapTop = previousContentFrame.maxY
            let gapBottom = contentFrame.minY

            if gapBottom > gapTop {
                let midpoint = (gapTop + gapBottom) / 2
                originY = midpoint - indicatorHeight / 2
                usedGapPlacement = true
            }
        }

        if originY < screenBounds.minY {
            originY = screenBounds.minY
        }
        if originY + indicatorHeight > screenBounds.maxY {
            originY = screenBounds.maxY - indicatorHeight
        }

        if !usedGapPlacement {
            let maxIndicatorBottom = fallbackBottom
            if originY + indicatorHeight > maxIndicatorBottom {
                originY = max(screenBounds.minY, maxIndicatorBottom - indicatorHeight)
            }
        }

        let indicatorFrame = CGRect(x: originX, y: originY, width: clampedWidth, height: indicatorHeight)
        return descriptor.screenToCocoa(indicatorFrame).standardized
    }

    internal func refreshIndicators() {
        // Refresh zone indicators
        var descriptors: [ZoneIndicatorDescriptor] = []

        for (screenId, context) in screenContexts {
            let screenDescriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                let frame = indicatorFrame(for: zone, controller: context.zoneController, descriptor: screenDescriptor)
                guard frame.width > 0, frame.height > 0 else {
                    continue
                }
                let descriptor = ZoneIndicatorDescriptor(
                    key: key,
                    cocoaFrame: frame,
                    isTargeted: key == targetedZoneKey
                )
                descriptors.append(descriptor)
            }
        }

        if descriptors.isEmpty {
            indicatorManager.tearDown()
        } else {
            indicatorManager.present(over: descriptors)
        }

        // Refresh add-zone indicators
        var addZoneDescriptors: [AddZoneIndicatorDescriptor] = []
        var newAddZoneHitAreas: [CGDirectDisplayID: CGRect] = [:]

        for (screenId, context) in screenContexts {
            let zoneCount = context.zoneController.allZones.count
            // Only show the indicator if there are fewer than 3 zones
            guard zoneCount < 3 else { continue }

            let screenDescriptor = context.descriptor
            guard let frames = addZoneIndicatorFrames(for: screenDescriptor) else {
                continue
            }
            let descriptor = AddZoneIndicatorDescriptor(
                screenId: screenId,
                frame: frames.cocoa
            )
            addZoneDescriptors.append(descriptor)
            newAddZoneHitAreas[screenId] = frames.accessibility
        }

        addIndicatorTracker.updateHitAreas(newAddZoneHitAreas)

        if addZoneDescriptors.isEmpty {
            addZoneIndicatorManager.updateDragHighlight(screenId: nil)
            addZoneIndicatorManager.tearDown()
        } else {
            addZoneIndicatorManager.present(for: addZoneDescriptors)
        }

        var temporaryDescriptors: [TemporaryZoneIndicatorDescriptor] = []
        var newTemporaryHitAreas: [CGDirectDisplayID: CGRect] = [:]
        for (screenId, context) in screenContexts {
            guard let frames = temporaryIndicatorFrames(for: context.descriptor) else {
                continue
            }
            let descriptor = TemporaryZoneIndicatorDescriptor(
                screenId: screenId,
                cocoaFrame: frames.cocoa,
                isTargeted: targetedTemporaryScreenId == screenId,
                isOccupied: temporaryZoneOccupant(on: screenId) != nil,
                isDragHighlighted: temporaryIndicatorTracker.highlightedScreenId == screenId
            )
            temporaryDescriptors.append(descriptor)
            newTemporaryHitAreas[screenId] = frames.accessibility
        }

        temporaryIndicatorTracker.updateHitAreas(newTemporaryHitAreas)

        if temporaryDescriptors.isEmpty {
            temporaryIndicatorTracker.setHighlightedScreen(nil)
            temporaryIndicatorManager.tearDown()
        } else {
            temporaryIndicatorManager.present(over: temporaryDescriptors)
        }
    }

    private func addZoneIndicatorFrames(for descriptor: ScreenDescriptor) -> (cocoa: CGRect, accessibility: CGRect)? {
        let bounds = descriptor.cocoaBounds.standardized
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        // Width: match the default pill thickness used by edge indicators.
        let indicatorWidth: CGFloat = EdgeIndicatorPillSizing.baseThickness

        // Height: 1/3 of screen height
        let indicatorHeight = bounds.height / 3

        // Position on the right edge, vertically centered
        let originX = bounds.maxX - indicatorWidth
        let originY = bounds.midY - indicatorHeight / 2

        let cocoaFrame = CGRect(x: originX, y: originY, width: indicatorWidth, height: indicatorHeight).standardized
        let screenFrame = descriptor.cocoaToScreen(cocoaFrame).standardized
        let accessibilityFrame = descriptor.screenToAccessibility(screenFrame).standardized
        return (cocoa: cocoaFrame, accessibility: accessibilityFrame)
    }

    private func temporaryIndicatorFrames(for descriptor: ScreenDescriptor) -> (cocoa: CGRect, accessibility: CGRect)? {
        let bounds = descriptor.visibleScreenBounds.standardized
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let width = min(max(bounds.width / 3, 80), bounds.width)
        let height: CGFloat = EdgeIndicatorPillSizing.baseThickness
        var originX = bounds.midX - width / 2
        originX = max(bounds.minX, min(originX, bounds.maxX - width))
        let originY = bounds.maxY - height
        let screenFrame = CGRect(x: originX, y: originY, width: width, height: height).standardized
        let cocoaFrame = descriptor.screenToCocoa(screenFrame).standardized
        let accessibilityFrame = descriptor.screenToAccessibility(screenFrame).standardized
        return (cocoa: cocoaFrame, accessibility: accessibilityFrame)
    }

    func addZoneIndicatorHitAreas() -> [CGDirectDisplayID: CGRect] {
        addIndicatorTracker.hitAreas
    }

    func updateAddZoneIndicatorHighlight(screenId: CGDirectDisplayID?) {
        if addIndicatorTracker.setHighlightedScreen(screenId) {
            addZoneIndicatorManager.updateDragHighlight(screenId: screenId)
        }
    }

    func temporaryIndicatorHitAreas() -> [CGDirectDisplayID: CGRect] {
        temporaryIndicatorTracker.hitAreas
    }

    func updateTemporaryIndicatorHighlight(screenId: CGDirectDisplayID?) {
        if temporaryIndicatorTracker.setHighlightedScreen(screenId) {
            temporaryIndicatorManager.updateDragHighlight(screenId: screenId)
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
    internal func syncWindowsToZones(excluding excludedZones: Set<ZoneKey> = [], recentlyPlacedInTempZone: Int? = nil) {
        // Merge explicit exclusions with zones that should not be touched while
        // a drag‑and‑drop session is in progress (origin/hovered zones).
        let effectiveExcludedZones = excludedZones.union(dragExcludedZones)
        let tempZoneExclusion = recentlyPlacedInTempZone

        // Ensure only one sync runs at a time. If a sync is already underway,
        // just record that another pass is needed and the combined exclusions;
        // the deferred block below will run a follow‑up sync when safe.
        if isSyncingWindows {
            pendingSync = true
            pendingSyncExcludedZones.formUnion(effectiveExcludedZones)
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
                let pendingExcluded = pendingSyncExcludedZones
                pendingSyncExcludedZones.removeAll()
                let pendingTempZoneExclusion = pendingSyncRecentlyPlacedInTempZone
                pendingSyncRecentlyPlacedInTempZone = nil
                syncWindowsToZones(excluding: pendingExcluded, recentlyPlacedInTempZone: pendingTempZoneExclusion)
            }
        }

        Logger.debug("Syncing windows to zones")

        // Phase 1: prune any windows that have been destroyed according to the
        // underlying Accessibility / CGWindow APIs, and remove them from zones
        // so no layout continues to reference dead windows.
        let prunedWindowIds = windowController.pruneDestroyedExternalWindows()
        if !prunedWindowIds.isEmpty {
            for windowId in prunedWindowIds {
                removeWindowFromAllZones(windowId: windowId, reason: "sync-prune-destroyed")
            }
        }

        // Snapshot of all known windows (real + placeholders). We pass this to
        // the placeholder coordinator so it can reuse existing placeholders.
        let existingWindows = windowController.allWindows

        // Tracks all non‑placeholder windows that end up with a valid zone
        // assignment in this pass. Anything not in this set (and not in the
        // temporary zone) will be detached from the tiling model at the end.
        var assignedWindowIds = Set<Int>()

        // Phase 2: walk every screen and zone, and for each zone that already
        // has a real window, move/resize that window into the zone’s content
        // frame (with margins) unless ActiveFit says to preserve reveal mode.
        for screenId in screenOrder {
            guard let context = screenContexts[screenId],
                  let descriptor = descriptor(for: screenId) else {
                continue
            }
            let controller = context.zoneController

            for zone in controller.allZones {
                if let windowId = zone.windowId,
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
                    // Normal case: compute the zone’s content frame (respecting
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

        // Phase 3: sync placeholder windows so every empty zone has a matching
        // placeholder (unless explicitly suppressed or excluded for this pass),
        // reusing existing placeholder windows where possible.
        placeholderCoordinator.syncPlaceholders(
            existingWindows: existingWindows,
            screenOrder: screenOrder,
            excludedZones: effectiveExcludedZones,
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
                    },
                    placeholderToZoneFrame: { frame, zone in
                        self.zoneFrame(fromContentFrame: frame, for: zone, in: context)
                    }
                )
            },
            shouldSuppressPlaceholder: { [weak self] key in
                guard let self = self else { return false }
                // UnderCovers suppresses the single-zone placeholder on that screen while active.
                return self.isUnderCoversActive(on: key.screenId) && key.index == 1
            }
        )

        let placeholderCount = windowController.allWindows.filter { $0.isPlaceholder }.count

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

        Logger.debug("Sync complete: assigned \(assignedWindowIds.count) window(s), placeholders \(placeholderCount), zones: \(occupiedZones) occupied, \(emptyZones) empty, excluded zones \(effectiveExcludedZones.count)")

        // Phase 4: clean up stale assignments. Any non‑placeholder window that
        // was *not* assigned to a tiled zone in this pass and is *not* parked
        // in the temporary floating zone should no longer be treated as zoned.
        for window in windowController.allWindows where !window.isPlaceholder {
            if assignedWindowIds.contains(window.windowId) {
                continue
            }
            if isWindowInTemporaryZone(window.windowId) {
                continue
            }
            clearManagedWindowZone(window)
        }

        // Phase 5: promote temporary zone occupants into any empty tiling zones.
        // This implements the spec rule: "When a tiling zone on a screen becomes
        // empty and that screen has a temporary-zone occupant, promote the
        // temporary window into the emptied zone."
        promoteTemporaryZoneOccupantsIfNeeded(excluding: tempZoneExclusion, reason: "sync")

        // Phase 6: ensure targeting and indicators are consistent with the new
        // layout — pick a valid targeted zone if needed, keep the temporary
        // zone's targeting model fresh, and refresh all on‑screen adornments.
        targetedZoneManager.ensureTargetedZone(reason: "sync")
        updateTemporaryZoneTargeting(reason: "sync")
        refreshIndicators()
        refreshResizeHandles()
        launcherController.repositionIfNeeded()
    }

    func shouldDeferPlacementForNewWindow(_ managed: ManagedWindow, targetedZoneKey: ZoneKey?) -> Bool {
        // Chrome merges kill the dragged window until the drop completes; avoid evicting the sibling.
        guard let targetedZoneKey = targetedZoneKey else {
            return false
        }
        guard case .accessibility(_, let pid, _) = managed.backing else {
            return false
        }
        guard MouseButtons.isLeftMouseButtonDown() else {
            return false
        }
        guard let context = screenContexts[targetedZoneKey.screenId],
              let zone = context.zoneController.zone(at: targetedZoneKey.index),
              let occupantId = zone.windowId,
              occupantId != managed.windowId,
              let occupant = windowController.window(withId: occupantId),
              !occupant.isPlaceholder,
              case .accessibility(_, let occupantPid, _) = occupant.backing,
              occupantPid == pid else {
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


    /// Convert a content frame (placeholder or occupant window) back into the zone frame.
    internal func zoneFrame(fromContentFrame frame: CGRect, for zone: Zone, in context: ScreenContext) -> CGRect {
        let margins = zoneMargins(for: zone, in: context.zoneController)

        var zoneFrame = frame.standardized
        zoneFrame.origin.x -= margins.left
        zoneFrame.origin.y -= margins.top
        zoneFrame.size.width += margins.left + margins.right
        zoneFrame.size.height += margins.top + margins.bottom
        let layoutBounds = context.zoneController.layoutBounds.standardized
        let pins = pinnedEdges(for: zone, in: context.zoneController)

        if pins.contains(.left) {
            let maxX = zoneFrame.maxX
            zoneFrame.origin.x = layoutBounds.minX
            zoneFrame.size.width = max(0, maxX - zoneFrame.origin.x)
        }

        if pins.contains(.right) {
            let minX = zoneFrame.minX
            zoneFrame.size.width = max(0, layoutBounds.maxX - minX)
        }

        if pins.contains(.top) {
            let maxY = zoneFrame.maxY
            zoneFrame.origin.y = layoutBounds.minY
            zoneFrame.size.height = max(0, maxY - zoneFrame.origin.y)
        }

        if pins.contains(.bottom) {
            let minY = zoneFrame.minY
            zoneFrame.size.height = max(0, layoutBounds.maxY - minY)
        }

        zoneFrame = clamp(frame: zoneFrame, to: layoutBounds)
        return zoneFrame
    }

    private struct ZoneEdgePinOptions: OptionSet {
        let rawValue: Int

        static let top = ZoneEdgePinOptions(rawValue: 1 << 0)
        static let bottom = ZoneEdgePinOptions(rawValue: 1 << 1)
        static let left = ZoneEdgePinOptions(rawValue: 1 << 2)
        static let right = ZoneEdgePinOptions(rawValue: 1 << 3)
    }

    private func pinnedEdges(for zone: Zone, in controller: ZoneController) -> ZoneEdgePinOptions {
        var pins: ZoneEdgePinOptions = []
        let zoneCount = controller.allZones.count

        if zone.index == 1 {
            pins.insert(.left)
        }

        if zoneCount >= 3 {
            if zone.index == 2 {
                pins.insert(.top)
            }
            if zone.index == 3 {
                pins.insert(.bottom)
            }
        }

        if zoneCount >= 2, zone.index >= 2 {
            pins.insert(.right)
        }

        return pins
    }

    private func clamp(frame: CGRect, to bounds: CGRect) -> CGRect {
        var normalized = frame.standardized

        let originX = max(bounds.minX, normalized.origin.x)
        let originY = max(bounds.minY, normalized.origin.y)
        let maxX = min(bounds.maxX, normalized.maxX)
        let maxY = min(bounds.maxY, normalized.maxY)

        normalized.origin = CGPoint(x: originX, y: originY)
        normalized.size.width = max(0, maxX - originX)
        normalized.size.height = max(0, maxY - originY)

        return normalized
    }

    // MARK: - ZoneResizeHandleManagerDelegate

    internal func beginZoneResizeDrag(screenId: CGDirectDisplayID, separatorIndex: Int) {
        Logger.debug("Zone resize drag began on \(screenContextStore.logDescription(for: screenId)) separator \(separatorIndex)")
        zoneResizeDragInProgress = true
        activeFitZoneResizeLoggedWindowIds.removeAll()
        // Return any window in reveal mode to rest mode before live resizing.
        exitRevealMode(reason: "zone-resize-begin")
    }

    internal func endZoneResizeDrag(screenId: CGDirectDisplayID, separatorIndex: Int) {
        Logger.debug("Zone resize drag ended on \(screenContextStore.logDescription(for: screenId)) separator \(separatorIndex)")
        zoneResizeDragInProgress = false
        activeFitZoneResizeLoggedWindowIds.removeAll()

        // When resizing stops, if the active window qualifies, re-evaluate ActiveFit.
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        handleActiveFitActivationCandidate(pid: pid)
    }

    func resizeHandleDragBegan(screenId: CGDirectDisplayID, separatorIndex: Int) {
        beginZoneResizeDrag(screenId: screenId, separatorIndex: separatorIndex)
    }

    func resizeHandleDragged(screenId: CGDirectDisplayID, separatorIndex: Int, delta: CGPoint) {
        guard let context = screenContexts[screenId] else { return }
        
        let separators = context.zoneController.separators()
        guard let separator = separators.first(where: { $0.index == separatorIndex }) else { return }
        
        let scalarDelta: CGFloat
        switch separator.orientation {
        case .vertical:
            scalarDelta = delta.x
        case .horizontal:
            scalarDelta = delta.y
        }
        
        guard abs(scalarDelta) > 0.001 else { return }
        
        // Apply resize
        context.zoneController.resizeBySeparator(index: separatorIndex, delta: scalarDelta)
        
        // Sync windows and handles to new layout
        syncWindowsToZones()
    }

    func resizeHandleDragEnded(screenId: CGDirectDisplayID, separatorIndex: Int) {
        endZoneResizeDrag(screenId: screenId, separatorIndex: separatorIndex)
    }

    internal func refreshResizeHandles() {
        var descriptors: [ZoneSeparatorDescriptor] = []
        let activeState = activeFitState

        for (screenId, context) in screenContexts {
            // When a screen's temporary zone holds a floating window,
            // hide all resize handles on that screen so they don't
            // overlap the temporary-zone UI.
            if temporaryZoneOccupant(on: screenId) != nil {
                continue
            }

            // When an unmanaged window has focus on this screen,
            // hide all resize handles on that screen to avoid overlapping it.
            if unmanagedFocusedWindowScreenId == screenId {
                continue
            }

            let separators = context.zoneController.separators()

            for sep in separators {
                var frame = sep.frame

                if let state = activeState,
                   state.zoneKey.screenId == screenId {
                    let activeFrame = state.revealFrame.standardized

                    switch sep.orientation {
                    case .vertical:
                        // Separator between zone 1 and zones 2/3 (index 0) should
                        // not extend into an ActiveFit window in zone 2 or 3.
                        if sep.index == 0, state.zoneKey.index >= 2 {
                            let originalFrame = frame.standardized
                            let intersection = originalFrame.intersection(activeFrame).standardized
                            if !intersection.isNull, intersection.height > 0 {
                                let topGap = max(0, intersection.minY - originalFrame.minY)
                                let bottomGap = max(0, originalFrame.maxY - intersection.maxY)
                                let maxGap = max(topGap, bottomGap)

                                // If the ActiveFit window fully covers the separator,
                                // hide this handle entirely.
                                guard maxGap > 0 else {
                                    continue
                                }

                                if topGap >= bottomGap {
                                    frame = CGRect(
                                        x: originalFrame.minX,
                                        y: originalFrame.minY,
                                        width: originalFrame.width,
                                        height: topGap
                                    )
                                } else {
                                    frame = CGRect(
                                        x: originalFrame.minX,
                                        y: intersection.maxY,
                                        width: originalFrame.width,
                                        height: bottomGap
                                    )
                                }
                            }
                        }

                    case .horizontal:
                        // Hide the separator between zones 2 and 3 (index 1) if it
                        // would overlap an ActiveFit window in zone 2 or 3.
                        if sep.index == 1, state.zoneKey.index >= 2 {
                            if frame.intersects(activeFrame) {
                                continue
                            }
                        }
                    }
                }

                descriptors.append(ZoneSeparatorDescriptor(
                    screenId: screenId,
                    index: sep.index,
                    orientation: sep.orientation,
                    frame: frame,
                    screenCocoaBounds: context.descriptor.cocoaBounds
                ))
            }
        }

        resizeHandleManager.present(over: descriptors)
    }

    // MARK: - Keyboard Shortcuts

    /// Clear all zones on active screen. If zones are already empty, go to one-zone configuration.
    internal func clearOrResetZones() {
        clearOrResetZones(on: activeScreenId(), reason: "shortcut-active-screen")
    }

    /// Run the clear/reset shortcut on the screen containing the mouse cursor (fallback to active).
    internal func clearOrResetZonesAtCursor() {
        if let cursorScreenId = resolveCursorScreenId() {
            clearOrResetZones(on: cursorScreenId, reason: "shortcut-cursor-screen")
        } else {
            Logger.debug("Clear/reset zones (shortcut-cursor-screen): cursor outside managed displays, falling back to active screen")
            clearOrResetZones()
        }
    }

    private func clearOrResetZones(on screenId: CGDirectDisplayID, reason: String) {
        guard let context = screenContexts[screenId] else {
            Logger.debug("Clear/reset zones (\(reason)): screen context unavailable")
            return
        }

        // Any clear/reset that operates on this screen should exit UnderCovers for it.
        endUnderCovers(on: screenId, reason: "clear-or-reset-zones-\(reason)", recreatePlaceholders: false)

        let zones = context.zoneController.allZones
        let allEmpty = zones.allSatisfy { $0.isEmpty }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)

        // WinShot: Create snapshot BEFORE clearing zones (if screen has windows)
        if !allEmpty || temporaryZoneCoordinator.occupant(on: screenId) != nil {
            createWinShotSnapshot(on: screenId, reason: "clear-zones-\(reason)")
        }

        // Also empty the temporary zone on the selected screen
        temporaryZoneCoordinator.minimizeOccupant(on: screenId, reason: "clear-zones-shortcut")

        if allEmpty {
            Logger.debug("Clear/reset zones (\(reason)): all zones empty on screen \(screenIndex), resetting to 1 zone")
            let removedWindowIds = context.zoneController.setZoneCount(to: 1)

            for windowId in removedWindowIds {
                if let managed = windowController.window(withId: windowId) {
                    windowPlacementManager.handleWindowAfterZoneRemoval(managed, preferredScreenId: screenId)
                }
            }

            placeholderCoordinator.clearMappingsForScreen(screenId)

            syncWindowsToZones()
            activeFitRefreshAfterZoneTopologyChange(reason: "reset-to-one-zone")
        } else {
            Logger.debug("Clear/reset zones (\(reason)): minimizing all windows on screen \(screenIndex)")
            var minimizedCount = 0
            var minimizedWindowIds: [Int] = []

            for zone in zones {
                if let windowId = zone.windowId,
                   let managed = windowController.window(withId: windowId),
                   !managed.isPlaceholder {
                    minimizeWindowProgrammatically(managed, reason: "clear-zones-shortcut")
                    removeWindowFromAllZones(windowId: windowId, reason: "clear-zones-shortcut", retarget: false)
                    minimizedCount += 1
                    minimizedWindowIds.append(windowId)
                }
            }

            Logger.debug("Clear/reset zones (\(reason)): minimized \(minimizedCount) window(s) on screen \(screenIndex)")
            syncWindowsToZones()
        }

        // After any clear/minimize cycle on this screen, explicitly target zone 1 on that screen.
        if context.zoneController.zone(at: 1) != nil {
            targetedZoneManager.setTargetedZone(ZoneKey(screenId: screenId, index: 1), reason: "clear-zones-shortcut")
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "clear-zones-shortcut-fallback")
        }

        // Auto-show Launcher after clearing zones (analogous to emptying a zone).
        autoShowLauncherIfEmptyTargetedTiledZone()
    }

    internal func resolveCursorScreenId() -> CGDirectDisplayID? {
        guard let cursorPoint = currentCursorAccessibilityPoint() else {
            return nil
        }

        for screenId in screenOrder {
            guard let context = screenContexts[screenId] else {
                continue
            }
            let descriptor = context.descriptor
            let screenBounds = descriptor.cocoaToScreen(descriptor.cocoaBounds)
            let accessibilityBounds = descriptor.screenToAccessibility(screenBounds)
            if accessibilityBounds.contains(cursorPoint) {
                return screenId
            }
        }

        return nil
    }

    /// Minimize the managed window under the mouse cursor, or remove the empty zone under the cursor.
    internal func minimizeWindowOrRemoveZoneAtCursor() {
        guard let cursorPoint = currentCursorAccessibilityPoint() else {
            Logger.debug("Cursor shortcut: unable to resolve cursor position; ignoring")
            return
        }

        // First priority: minimize a managed (non-placeholder) window under the cursor.
        if let (managed, pid) = managedWindowUnderCursor(cursorPoint: cursorPoint) {
            // Get window title for logging (best-effort).
            var windowTitle = "untitled"
            if case .accessibility(let element, _, _) = managed.backing {
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
                   let title = value as? String,
                   !title.isEmpty {
                    windowTitle = title
                }
            }

            Logger.debug(
                "minimizeWindowOrRemoveZoneAtCursor: Minimizing window \(managed.windowId) from pid \(pid) (\(windowTitle))"
            )

            let emptiedZoneKey = zoneKey(forManagedWindow: managed)

            // Exit UnderCovers on the screen where this window lives, if applicable.
            if let screenId = managed.screenDisplayId ?? detectScreenId(for: managed) {
                endUnderCovers(on: screenId, reason: "cursor-shortcut-minimize", recreatePlaceholders: false)
            }

            let wasManualResizeDetached = performProgrammaticMinimizeCleanup(
                managed,
                minimizeReason: "cursor-shortcut-minimize",
                cleanupReason: "cursor-shortcut-minimize",
                retarget: true
            )
            syncWindowsToZones()

            scheduleMinimizeVerification(
                windowId: managed.windowId,
                emptiedZoneKey: emptiedZoneKey,
                minimizeReason: "cursor-shortcut-minimize",
                cleanupReason: "cursor-shortcut-minimize",
                wasManualResizeDetached: wasManualResizeDetached
            )
            return
        }

        // Second priority: remove the empty zone under the cursor (placeholder frame).
        if let zoneKey = emptyZoneKeyUnderCursor(cursorPoint: cursorPoint) {
            let screenIndex = screenContextStore.loggingIndex(for: zoneKey.screenId)
            Logger.debug(
                "minimizeWindowOrRemoveZoneAtCursor: Removing zone \(zoneKey.index) on screen \(screenIndex) under cursor"
            )
            endUnderCovers(on: zoneKey.screenId, reason: "cursor-shortcut-remove-zone", recreatePlaceholders: false)
            _ = performRemoveZone(at: zoneKey.index, on: zoneKey.screenId, announce: false)
            return
        }

        Logger.debug("minimizeWindowOrRemoveZoneAtCursor: No managed window or empty zone under cursor; doing nothing")
    }

    /// Find the topmost managed (non-placeholder) window under the cursor on the cursor's screen.
    private func managedWindowUnderCursor(cursorPoint: CGPoint) -> (ManagedWindow, pid_t)? {
        guard let screenId = resolveCursorScreenId(),
              let context = screenContexts[screenId] else {
            return nil
        }

        // Temporary zone floats above all tiled zones; return immediately if cursor is within it.
        if let tempOccupant = temporaryZoneOccupant(on: screenId),
           case .accessibility(_, let pid, _) = tempOccupant.backing,
           let frame = windowController.actualFrameInAccessibilityCoordinates(for: tempOccupant),
           frame.contains(cursorPoint) {
            return (tempOccupant, pid)
        }

        // Collect tiled zone candidates under cursor: (ManagedWindow, pid, cgWindowId).
        var candidates: [(ManagedWindow, pid_t, Int)] = []
        for zone in context.zoneController.allZones {
            guard let windowId = zone.windowId,
                  let managed = windowController.window(withId: windowId),
                  !managed.isPlaceholder,
                  case .accessibility(_, let pid, let cgWindowId) = managed.backing,
                  let frame = windowController.actualFrameInAccessibilityCoordinates(for: managed),
                  frame.contains(cursorPoint) else {
                continue
            }
            candidates.append((managed, pid, cgWindowId))
        }

        // Fast paths: 0 or 1 tiled candidate.
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            let (managed, pid, _) = candidates[0]
            return (managed, pid)
        }

        // Multiple tiled candidates (e.g., ActiveFit overlap): use CG API to find topmost.
        let candidateCGIds = Set(candidates.map { $0.2 })
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            let (managed, pid, _) = candidates[0]
            return (managed, pid)
        }

        for windowInfo in windowList {
            guard let cgWindowId = windowInfo[kCGWindowNumber as String] as? Int,
                  candidateCGIds.contains(cgWindowId),
                  let match = candidates.first(where: { $0.2 == cgWindowId }) else {
                continue
            }
            return (match.0, match.1)
        }

        let (managed, pid, _) = candidates[0]
        return (managed, pid)
    }

    /// Find the empty zone (placeholder frame) under the cursor, if any.
    private func emptyZoneKeyUnderCursor(cursorPoint: CGPoint) -> ZoneKey? {
        for (screenId, context) in screenContexts {
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones where zone.isEmpty {
                let accessibilityZone = descriptor.screenToAccessibility(zone.frame)
                if accessibilityZone.contains(cursorPoint) {
                    return ZoneKey(screenId: screenId, index: zone.index)
                }
            }
        }
        return nil
    }

    /// Target the temporary zone, preferring the screen of the currently targeted normal zone
    internal func targetTemporaryZone() {
        guard let targetedZone = targetedZoneManager.targetedZoneKey else {
            Logger.debug("Target temporary zone: normal zone not targeted; shortcut ignored")
            return
        }

        let preferredScreenId: CGDirectDisplayID
        if screenContexts[targetedZone.screenId] != nil {
            preferredScreenId = targetedZone.screenId
        } else {
            let active = activeScreenId()
            if screenContexts[active] != nil {
                preferredScreenId = active
            } else {
                preferredScreenId = screenOrder.first ?? active
            }
        }

        let screenIndex = screenContextStore.loggingIndex(for: preferredScreenId)
        Logger.debug("Target temporary zone: setting temporary zone on screen \(screenIndex) as target")
        targetedZoneManager.setTemporaryTarget(on: preferredScreenId, reason: "shortcut-target-temporary")
    }

    /// Target tiling zone: from temporary zone to normal zone on same screen
    internal func targetTilingZone() {
        guard let targetedTemporaryScreenId = targetedZoneManager.targetedTemporaryScreenId else {
            Logger.debug("Target tiling zone: temporary zone not targeted, doing nothing")
            return
        }

        guard let context = screenContexts[targetedTemporaryScreenId] else {
            Logger.debug("Target tiling zone: no context for temporary zone screen")
            return
        }

        let zones = context.zoneController.allZones

        // Prefer empty tiling zone with lowest index
        let emptyZones = zones.filter { $0.isEmpty }.sorted { $0.index < $1.index }
        if let firstEmptyZone = emptyZones.first {
            let zoneKey = ZoneKey(screenId: targetedTemporaryScreenId, index: firstEmptyZone.index)
            Logger.debug("Target tiling zone: targeting empty zone \(firstEmptyZone.index) on screen \(screenContextStore.loggingIndex(for: targetedTemporaryScreenId))")
            targetedZoneManager.setTargetedZone(zoneKey, reason: "shortcut-target-tiling-zone")
            return
        }

        // If no empty zone, target filled zone with highest index
        let filledZones = zones.filter { !$0.isEmpty }.sorted { $0.index > $1.index }
        if let firstFilledZone = filledZones.first {
            let zoneKey = ZoneKey(screenId: targetedTemporaryScreenId, index: firstFilledZone.index)
            Logger.debug("Target tiling zone: targeting filled zone \(firstFilledZone.index) on screen \(screenContextStore.loggingIndex(for: targetedTemporaryScreenId))")
            targetedZoneManager.setTargetedZone(zoneKey, reason: "shortcut-target-tiling-zone")
            return
        }

        Logger.debug("Target tiling zone: no zones available on screen")
    }

    /// Navigate left: between zones or screens
    internal func navigateLeft() {
        // If temporary zone is targeted, go to temporary zone on screen to the left
        if let targetedTemporaryScreenId = targetedZoneManager.targetedTemporaryScreenId {
            navigateTemporaryZoneLeft(from: targetedTemporaryScreenId)
            return
        }

        // If normal zone is targeted, navigate to lower index or previous screen
        if let targetedKey = targetedZoneManager.targetedZoneKey {
            navigateNormalZoneLeft(from: targetedKey)
            return
        }

        Logger.debug("Navigate left: no zone targeted")
    }

    /// Navigate right: between zones or screens
    internal func navigateRight() {
        // If temporary zone is targeted, go to temporary zone on screen to the right
        if let targetedTemporaryScreenId = targetedZoneManager.targetedTemporaryScreenId {
            navigateTemporaryZoneRight(from: targetedTemporaryScreenId)
            return
        }

        // If normal zone is targeted, navigate to higher index or next screen
        if let targetedKey = targetedZoneManager.targetedZoneKey {
            navigateNormalZoneRight(from: targetedKey)
            return
        }

        Logger.debug("Navigate right: no zone targeted")
    }

    private func navigateTemporaryZoneLeft(from currentScreenId: CGDirectDisplayID) {
        let screens = screenOrderLeftToRight
        guard let currentIndex = screens.firstIndex(of: currentScreenId), currentIndex > 0 else {
            Logger.debug("Navigate left (temp): already at leftmost screen")
            return
        }

        let leftScreenId = screens[currentIndex - 1]
        Logger.debug("Navigate left (temp): targeting temporary zone on screen \(screenContextStore.loggingIndex(for: leftScreenId))")
        targetedZoneManager.setTemporaryTarget(on: leftScreenId, reason: "shortcut-navigate-left-temp")
    }

    private func navigateTemporaryZoneRight(from currentScreenId: CGDirectDisplayID) {
        let screens = screenOrderLeftToRight
        guard let currentIndex = screens.firstIndex(of: currentScreenId), currentIndex < screens.count - 1 else {
            Logger.debug("Navigate right (temp): already at rightmost screen")
            return
        }

        let rightScreenId = screens[currentIndex + 1]
        Logger.debug("Navigate right (temp): targeting temporary zone on screen \(screenContextStore.loggingIndex(for: rightScreenId))")
        targetedZoneManager.setTemporaryTarget(on: rightScreenId, reason: "shortcut-navigate-right-temp")
    }

    private func navigateNormalZoneLeft(from currentKey: ZoneKey) {
        guard let context = screenContexts[currentKey.screenId] else {
            Logger.debug("Navigate left (normal): no context for current screen")
            return
        }

        let zones = context.zoneController.allZones.sorted { $0.index < $1.index }

        // Try to find zone with lower index on same screen
        if let lowerZone = zones.last(where: { $0.index < currentKey.index }) {
            let newKey = ZoneKey(screenId: currentKey.screenId, index: lowerZone.index)
            Logger.debug("Navigate left (normal): targeting zone \(lowerZone.index) on same screen")
            targetedZoneManager.setTargetedZone(newKey, reason: "shortcut-navigate-left-normal")
            return
        }

        // If at first zone, wrap to previous screen
        let screens = screenOrderLeftToRight
        guard let currentScreenIndex = screens.firstIndex(of: currentKey.screenId), currentScreenIndex > 0 else {
            Logger.debug("Navigate left (normal): at first zone on first screen")
            return
        }

        let leftScreenId = screens[currentScreenIndex - 1]
        guard let leftContext = screenContexts[leftScreenId] else {
            Logger.debug("Navigate left (normal): no context for left screen")
            return
        }

        let leftZones = leftContext.zoneController.allZones.sorted { $0.index > $1.index }
        if let lastZone = leftZones.first {
            let newKey = ZoneKey(screenId: leftScreenId, index: lastZone.index)
            Logger.debug("Navigate left (normal): wrapping to zone \(lastZone.index) on screen \(screenContextStore.loggingIndex(for: leftScreenId))")
            targetedZoneManager.setTargetedZone(newKey, reason: "shortcut-navigate-left-normal-wrap")
        }
    }

    private func navigateNormalZoneRight(from currentKey: ZoneKey) {
        guard let context = screenContexts[currentKey.screenId] else {
            Logger.debug("Navigate right (normal): no context for current screen")
            return
        }

        let zones = context.zoneController.allZones.sorted { $0.index < $1.index }

        // Try to find zone with higher index on same screen
        if let higherZone = zones.first(where: { $0.index > currentKey.index }) {
            let newKey = ZoneKey(screenId: currentKey.screenId, index: higherZone.index)
            Logger.debug("Navigate right (normal): targeting zone \(higherZone.index) on same screen")
            targetedZoneManager.setTargetedZone(newKey, reason: "shortcut-navigate-right-normal")
            return
        }

        // If at last zone, wrap to next screen
        let screens = screenOrderLeftToRight
        guard let currentScreenIndex = screens.firstIndex(of: currentKey.screenId),
              currentScreenIndex < screens.count - 1 else {
            Logger.debug("Navigate right (normal): at last zone on last screen")
            return
        }

        let rightScreenId = screens[currentScreenIndex + 1]
        guard let rightContext = screenContexts[rightScreenId] else {
            Logger.debug("Navigate right (normal): no context for right screen")
            return
        }

        let rightZones = rightContext.zoneController.allZones.sorted { $0.index < $1.index }
        if let firstZone = rightZones.first {
            let newKey = ZoneKey(screenId: rightScreenId, index: firstZone.index)
            Logger.debug("Navigate right (normal): wrapping to zone \(firstZone.index) on screen \(screenContextStore.loggingIndex(for: rightScreenId))")
            targetedZoneManager.setTargetedZone(newKey, reason: "shortcut-navigate-right-normal-wrap")
        }
    }

    // MARK: - Event suppression helpers

    /// Suppress the next `count` occurrences of the given events for specific windows. Entries self-expire after `timeout`.
    internal func suppressNextEvents(
        for windowIds: [Int],
        events: Set<AppController.SuppressedEvent>,
        count: Int,
        timeout: TimeInterval = 3.0,
        reason: String
    ) {
        guard !windowIds.isEmpty, !events.isEmpty, count > 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        for windowId in windowIds {
            var suppressions = eventSuppressions[windowId] ?? [:]
            for event in events {
                suppressions[event] = SuppressionEntry(remaining: count, deadline: deadline)
            }
            eventSuppressions[windowId] = suppressions
        }
        let eventList = events.map { $0.rawValue }.joined(separator: ",")
        Logger.debug(
            "Suppressing next \(count) event(s) [\(eventList)] for windows \(windowIds) until \(deadline) (reason: \(reason))"
        )
    }

    /// Convenience overload for suppressing the next single occurrence of a set of events.
    internal func suppressNextEvents(
        for windowIds: [Int],
        events: Set<AppController.SuppressedEvent>,
        timeout: TimeInterval = 3.0,
        reason: String
    ) {
        suppressNextEvents(for: windowIds, events: events, count: 1, timeout: timeout, reason: reason)
    }

    internal func isEventSuppressed(windowId: Int, event: AppController.SuppressedEvent) -> Bool {
        let now = Date()
        guard var suppressions = eventSuppressions[windowId],
              var entry = suppressions[event] else {
            return false
        }

        if entry.deadline < now || entry.remaining <= 0 {
            suppressions.removeValue(forKey: event)
            if suppressions.isEmpty {
                eventSuppressions.removeValue(forKey: windowId)
            } else {
                eventSuppressions[windowId] = suppressions
            }
            return false
        }

        entry.remaining -= 1
        suppressions[event] = entry.remaining > 0 ? entry : nil
        if suppressions[event] == nil {
            suppressions.removeValue(forKey: event)
        }
        if suppressions.isEmpty {
            eventSuppressions.removeValue(forKey: windowId)
        } else {
            eventSuppressions[windowId] = suppressions
        }

        Logger.debug("Suppressed event \(event.rawValue) for window \(windowId)")
        return true
    }

    // MARK: - Programmatic actions

    internal func minimizeWindowProgrammatically(
        _ managed: ManagedWindow,
        reason: String,
        suppressTimeout: TimeInterval = 3.0
    ) {
        suppressNextEvents(for: [managed.windowId], events: [.miniaturized], timeout: suppressTimeout, reason: reason)
        windowController.minimizeWindow(managed)
    }

    @discardableResult
    internal func performProgrammaticMinimizeCleanup(
        _ managed: ManagedWindow,
        minimizeReason: String,
        cleanupReason: String,
        retarget: Bool = true
    ) -> Bool {
        let wasManualResizeDetached = manualResizeDetachedWindowIds.contains(managed.windowId)
        minimizeWindowProgrammatically(managed, reason: minimizeReason)
        manualResizeDetachedWindowIds.remove(managed.windowId)
        removeWindowFromAllZones(windowId: managed.windowId, reason: cleanupReason, retarget: retarget)
        return wasManualResizeDetached
    }

    internal func finalizeProgrammaticMinimize(
        windowId: Int,
        emptiedZoneKey: ZoneKey?,
        reason: String
    ) {
        // Note: emptiedZoneKey is no longer used - temporary zone promotion is now
        // handled centrally by syncWindowsToZones. Keeping parameter for API stability.
        _ = emptiedZoneKey

        clearRevealModeForWindow(windowId: windowId, transitionToRest: false, reason: reason)
        activeFitClearSuppressionForWindow(windowId)
    }

    internal func scheduleMinimizeVerification(
        windowId: Int,
        emptiedZoneKey: ZoneKey?,
        minimizeReason: String,
        cleanupReason: String,
        wasManualResizeDetached: Bool,
        attempt: Int = 1
    ) {
        let delay: TimeInterval = attempt == 1 ? 0.12 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard let managed = self.windowController.window(withId: windowId) else {
                Logger.debug("Minimize verification: window \(windowId) no longer tracked (reason: \(cleanupReason))")
                return
            }

            let pidDescription: String = {
                if case .accessibility(_, let pid, let cgWindowId) = managed.backing {
                    return "pid \(pid), cgWindowId \(cgWindowId)"
                }
                return "appkit"
            }()
            Logger.debug(
                "Minimize verification attempt \(attempt) for window \(windowId) (\(pidDescription)), " +
                "isMinimized=\(managed.isMinimized) (reason: \(cleanupReason))"
            )

            if managed.isMinimized {
                Logger.debug("Minimize verification succeeded for window \(windowId) on attempt \(attempt)")
                self.finalizeProgrammaticMinimize(
                    windowId: windowId,
                    emptiedZoneKey: emptiedZoneKey,
                    reason: cleanupReason
                )
                return
            }

            if attempt == 1 {
                Logger.debug("Minimize verification failed for window \(windowId); retrying (reason: \(cleanupReason))")
                self.minimizeWindowProgrammatically(managed, reason: minimizeReason)
                self.scheduleMinimizeVerification(
                    windowId: windowId,
                    emptiedZoneKey: emptiedZoneKey,
                    minimizeReason: minimizeReason,
                    cleanupReason: cleanupReason,
                    wasManualResizeDetached: wasManualResizeDetached,
                    attempt: 2
                )
                return
            }

            self.rollbackFailedProgrammaticMinimize(
                managed,
                emptiedZoneKey: emptiedZoneKey,
                cleanupReason: cleanupReason,
                wasManualResizeDetached: wasManualResizeDetached
            )
        }
    }

    private func rollbackFailedProgrammaticMinimize(
        _ managed: ManagedWindow,
        emptiedZoneKey: ZoneKey?,
        cleanupReason: String,
        wasManualResizeDetached: Bool
    ) {
        guard !managed.isMinimized else {
            finalizeProgrammaticMinimize(
                windowId: managed.windowId,
                emptiedZoneKey: emptiedZoneKey,
                reason: cleanupReason
            )
            return
        }

        if wasManualResizeDetached {
            manualResizeDetachedWindowIds.insert(managed.windowId)
        }

        guard let key = emptiedZoneKey else {
            Logger.debug("Minimize rollback: window \(managed.windowId) has no prior zone (reason: \(cleanupReason))")
            return
        }

        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
        Logger.debug(
            "Minimize rollback: restoring window \(managed.windowId) to zone \(key.index) on screen \(screenIndex) (reason: \(cleanupReason))"
        )
        windowPlacementManager.placeWindow(managed, into: key, reason: "\(cleanupReason)-rollback")
    }

    // Protocol convenience overload (no duration parameter)
    internal func minimizeWindowProgrammatically(
        _ managed: ManagedWindow,
        reason: String
    ) {
        minimizeWindowProgrammatically(managed, reason: reason, suppressTimeout: 3.0)
    }

    /// Minimizes the currently active/key window using Cmd-M shortcut override
    internal func minimizeActiveWindow() {
        // Try to get the frontmost managed window
        guard let (managed, pid) = managedWindowForFrontmostApplication(
            logPrefix: "minimizeActiveWindow"
        ) else {
            Logger.debug("minimizeActiveWindow: No eligible frontmost window to minimize")
            return
        }

        let emptiedZoneKey = zoneKey(forManagedWindow: managed)

        // Get window title for logging
        var windowTitle = "untitled"
        if case .accessibility(let element, _, _) = managed.backing {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
               let title = value as? String,
               !title.isEmpty {
                windowTitle = title
            }
        }

        Logger.debug(
            "minimizeActiveWindow: Minimizing window \(managed.windowId) from pid \(pid) " +
            "(\(windowTitle))"
        )

        let wasManualResizeDetached = performProgrammaticMinimizeCleanup(
            managed,
            minimizeReason: "cmd-m-override",
            cleanupReason: "cmd-m-minimize",
            retarget: true
        )
        syncWindowsToZones()

        scheduleMinimizeVerification(
            windowId: managed.windowId,
            emptiedZoneKey: emptiedZoneKey,
            minimizeReason: "cmd-m-override",
            cleanupReason: "cmd-m-minimize",
            wasManualResizeDetached: wasManualResizeDetached
        )
    }

}
