import Foundation
import AppKit

/// Zone navigation: keyboard shortcuts and cursor-based zone operations.
extension AppController {

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

        // WinShot: capture the pre-clear state before applying bulk clear/reset changes.
        autoSavePreClearWinShotSnapshotIfNeeded(on: screenId, clearReason: reason)

        // Clear the floating zone occupant (bookkeeping only, minimize batched below).
        let floatingOccupant = floatingZoneCoordinator.occupant(on: screenId)
        if let floatingOccupant {
            floatingZoneCoordinator.clear(windowId: floatingOccupant.windowId, minimize: false, reason: "clear-zones-shortcut")
        }

        if allEmpty {
            // Minimize floating zone occupant if any
            if let floatingOccupant {
                minimizeWindowProgrammatically(floatingOccupant, reason: "clear-zones-shortcut")
                scheduleMinimizeVerification(
                    windowId: floatingOccupant.windowId,
                    emptiedZoneKey: nil,
                    minimizeReason: "clear-zones-shortcut",
                    cleanupReason: "clear-zones-shortcut",
                    manualResizeState: ManualResizeCleanupState(wasDetached: false, rememberedSize: nil)
                )
            }

            Logger.debug("Clear/reset zones (\(reason)): all zones empty on screen \(screenIndex), resetting to 1 zone")
            clearRememberedManualResizeSizes(on: screenId, reason: "reset-to-one-zone")
            let removedWindowIds = context.zoneController.setZoneCount(to: 1)

            for windowId in removedWindowIds {
                if let managed = windowController.window(withId: windowId) {
                    windowPlacementManager.handleWindowAfterZoneRemoval(managed)
                }
            }

            placeholderCoordinator.clearPlaceholdersForScreen(screenId)

            syncWindowsToZones()
            activeFitRefreshAfterZoneTopologyChange(reason: "reset-to-one-zone")
        } else {
            Logger.debug("Clear/reset zones (\(reason)): minimizing all windows on screen \(screenIndex)")

            // Optimistically target tiling zone 1 and show the Launcher before kicking off
            // the bulk AX minimize. The post-minimize retarget + auto-show inside the
            // dispatched block below remains as an idempotent safety net for when the
            // optimistic path is skipped (preference off, full-screen pause, unmanaged-focused-window).
            if context.zoneController.zone(at: 1) != nil {
                optimisticallyShowLauncher(
                    targetingZone: ZoneKey(screenId: screenId, index: 1),
                    reason: "clear-zones-optimistic"
                )
            }

            // Collect all windows to minimize (floating zone + tiled zones) synchronously,
            // while the pre-minimize zone state is still accurate.
            var windowsToMinimize: [ManagedWindow] = []
            if let floatingOccupant {
                windowsToMinimize.append(floatingOccupant)
            }
            for zone in zones {
                if let windowId = zone.occupantWindowId,
                   let managed = windowController.window(withId: windowId) {
                    windowsToMinimize.append(managed)
                }
            }

            // Dispatch the blocking AX minimize cascade (and post-minimize target/auto-show
            // safety net) to the next run-loop tick so the Launcher's newly-ordered window
            // actually renders — `makeKeyAndOrderFront` only queues the draw; each AX
            // minimize is a synchronous cross-process call that would otherwise hold the
            // main thread until after every window finishes minimizing.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let minimizedWindowIds = windowsToMinimize.map(\.windowId)
                self.bulkProgrammaticMinimize(
                    windowsToMinimize,
                    minimizeReason: "clear-zones-shortcut",
                    cleanupReason: "clear-zones-shortcut"
                ) { managed in
                    self.removeWindowFromAllZones(windowId: managed.windowId, reason: "clear-zones-shortcut", retarget: false)
                }
                Logger.debug("Clear/reset zones (\(reason)): minimized \(minimizedWindowIds.count) window(s) on screen \(screenIndex)")
                self.syncWindowsToZones()

                if let ctx = self.screenContexts[screenId], ctx.zoneController.zone(at: 1) != nil {
                    self.targetedZoneManager.setTargetedZone(ZoneKey(screenId: screenId, index: 1), reason: "clear-zones-shortcut")
                } else {
                    self.targetedZoneManager.ensureTargetedZone(reason: "clear-zones-shortcut-fallback")
                }
                self.autoShowLauncherIfEmptyTargetedTiledZone()
            }
            return
        }

        // Reset branch only: target zone 1 and auto-show Launcher.
        if context.zoneController.zone(at: 1) != nil {
            targetedZoneManager.setTargetedZone(ZoneKey(screenId: screenId, index: 1), reason: "clear-zones-shortcut")
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "clear-zones-shortcut-fallback")
        }
        autoShowLauncherIfEmptyTargetedTiledZone()
    }

    internal func resolveCursorScreenId() -> CGDirectDisplayID? {
        guard let cursorPoint = currentCursorAccessibilityPoint() else {
            return nil
        }

        return screenId(containingAccessibilityPoint: cursorPoint)
    }

    internal func screenId(containingAccessibilityPoint point: CGPoint) -> CGDirectDisplayID? {
        for screenId in screenOrder {
            guard let context = screenContexts[screenId] else {
                continue
            }
            let descriptor = context.descriptor
            let screenBounds = descriptor.cocoaToScreen(descriptor.cocoaBounds)
            let accessibilityBounds = descriptor.screenToAccessibility(screenBounds)
            if accessibilityBounds.contains(point) {
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
        if let (managed, pid) = managedWindowAtAccessibilityPoint(cursorPoint) {
            // Get window title for logging (best-effort).
            var windowTitle = "untitled"
            let element = managed.backing.element
            var value: CFTypeRef?
            if AXCall.copyAttribute(element, kAXTitleAttribute as CFString, &value) == .success,
               let title = value as? String,
               !title.isEmpty {
                windowTitle = title
            }

            Logger.debug(
                "minimizeWindowOrRemoveZoneAtCursor: Minimizing window \(managed.windowId) from pid \(pid) (\(windowTitle))"
            )

            // Exit UnderCovers on the screen where this window lives, if applicable.
            if let screenId = managed.screenDisplayId ?? detectScreenId(for: managed) {
                endUnderCovers(on: screenId, reason: "cursor-shortcut-minimize", recreatePlaceholders: false)
            }

            // Optimistically retarget and show the Launcher before the AX miniaturize
            // notification arrives. Zone bookkeeping is left to the notification handler so a
            // cancelled minimize doesn't orphan the window.
            optimisticallyShowLauncherForMinimize(managed, reason: "cursor-minimize-optimistic")
            windowController.minimizeWindow(managed)
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

    /// Find the topmost tiled managed (non-placeholder) window at the given accessibility point.
    internal func tiledManagedWindowAtAccessibilityPoint(_ point: CGPoint) -> (ManagedWindow, pid_t)? {
        resolveManagedWindowAtAccessibilityPoint(point, includeFloating: false)
    }

    /// Find the topmost managed (non-placeholder) window at the given accessibility point.
    internal func managedWindowAtAccessibilityPoint(_ point: CGPoint) -> (ManagedWindow, pid_t)? {
        resolveManagedWindowAtAccessibilityPoint(point, includeFloating: true)
    }

    /// Backwards-compatible wrapper for existing cursor-based callers.
    internal func tiledManagedWindowUnderCursor(cursorPoint: CGPoint) -> (ManagedWindow, pid_t)? {
        tiledManagedWindowAtAccessibilityPoint(cursorPoint)
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

    private func resolveManagedWindowAtAccessibilityPoint(
        _ point: CGPoint,
        includeFloating: Bool
    ) -> (ManagedWindow, pid_t)? {
        guard let screenId = screenId(containingAccessibilityPoint: point),
              let context = screenContexts[screenId] else {
            return nil
        }

        var candidates: [(managed: ManagedWindow, pid: pid_t, cgWindowId: Int)] = []

        if includeFloating,
           let floatingOccupant = floatingZoneOccupant(on: screenId),
           let frame = windowController.actualFrameInAccessibilityCoordinates(for: floatingOccupant),
           frame.contains(point) {
            candidates.append(
                (floatingOccupant, floatingOccupant.backing.pid, floatingOccupant.backing.cgWindowId)
            )
        }

        for zone in context.zoneController.allZones {
            guard let windowId = zone.occupantWindowId,
                  let managed = windowController.window(withId: windowId),
                  let frame = windowController.actualFrameInAccessibilityCoordinates(for: managed),
                  frame.contains(point) else {
                continue
            }
            candidates.append((managed, managed.backing.pid, managed.backing.cgWindowId))
        }

        guard !candidates.isEmpty else {
            return nil
        }
        if candidates.count == 1 {
            let candidate = candidates[0]
            return (candidate.managed, candidate.pid)
        }

        let candidateCGIds = Set(candidates.map(\.cgWindowId))
        guard let windowNumbers = WindowServerWindowList.onScreenWindowNumbersFrontToBack() else {
            let candidate = candidates[0]
            return (candidate.managed, candidate.pid)
        }

        for cgWindowId in windowNumbers where candidateCGIds.contains(cgWindowId) {
            if let match = candidates.first(where: { $0.cgWindowId == cgWindowId }) {
                return (match.managed, match.pid)
            }
        }

        let candidate = candidates[0]
        return (candidate.managed, candidate.pid)
    }

    // MARK: - Directional Target Navigation

    /// Control-Command + an arrow key moves the target to the nearest zone in that physical
    /// direction. Every tiling zone and each screen's floating zone is treated as a rectangle on
    /// one global plane; the selection itself lives in `DirectionalZoneNavigation`.
    internal func navigateTarget(_ direction: ZoneNavigationDirection) {
        performTargetChangeKeepingLauncherVisible {
            applyDirectionalNavigation(direction)
        }
    }

    private func applyDirectionalNavigation(_ direction: ZoneNavigationDirection) {
        guard let current = currentNavigableZoneIdentifier() else {
            Logger.debug("Directional navigation (\(direction)): no zone targeted; ignoring")
            return
        }

        guard let next = DirectionalZoneNavigation.nextZone(
            from: current,
            direction: direction,
            among: navigableZones()
        ) else {
            Logger.debug("Directional navigation (\(direction)): no zone in that direction; staying put")
            return
        }

        switch next {
        case let .tiling(screenId, index):
            Logger.debug("Directional navigation (\(direction)): targeting zone \(index) on screen \(screenContextStore.loggingIndex(for: screenId))")
            targetedZoneManager.setTargetedZone(
                ZoneKey(screenId: screenId, index: index),
                reason: "shortcut-navigate-\(direction)"
            )
        case let .floating(screenId):
            Logger.debug("Directional navigation (\(direction)): targeting floating zone on screen \(screenContextStore.loggingIndex(for: screenId))")
            targetedZoneManager.setFloatingTarget(on: screenId, reason: "shortcut-navigate-\(direction)")
        }
    }

    /// The currently targeted zone expressed as a navigation identifier.
    private func currentNavigableZoneIdentifier() -> NavigableZoneIdentifier? {
        if let key = targetedZoneManager.targetedZoneKey {
            return .tiling(screenId: key.screenId, index: key.index)
        }
        if let screenId = targetedZoneManager.targetedFloatingScreenId {
            return .floating(screenId: screenId)
        }
        return nil
    }

    /// Every currently targetable zone, as rectangles on the shared global (accessibility-
    /// coordinate) plane: each tiling zone plus the screen's floating-zone bar.
    private func navigableZones() -> [NavigableZone] {
        var zones: [NavigableZone] = []
        for screenId in screenOrder {
            // Reuse the canonical targetability policy so navigation reaches exactly the zones the
            // rest of targeting considers valid (this also keeps the all-screens-full-screen
            // fallback screen reachable).
            guard targetedZoneManager.isScreenTargetable(screenId),
                  let context = screenContexts[screenId] else {
                continue
            }
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                zones.append(
                    NavigableZone(
                        id: .tiling(screenId: screenId, index: zone.index),
                        frame: descriptor.screenToAccessibility(zone.frame)
                    )
                )
            }
            if let floatingFrame = floatingIndicatorFrames(for: descriptor)?.accessibility {
                zones.append(NavigableZone(id: .floating(screenId: screenId), frame: floatingFrame))
            }
        }
        return zones
    }

    /// Wrap a target-changing keyboard shortcut so a visible Launcher follows the new target
    /// instead of dismissing on occupied tiling zones, and a closed Launcher stays closed (no
    /// auto-show is triggered). Used by directional navigation and "Toggle Target Zone w/ Focused
    /// Window".
    internal func performTargetChangeKeepingLauncherVisible(_ block: () -> Void) {
        let previous = keepLauncherVisibleAcrossTargetNavigation
        keepLauncherVisibleAcrossTargetNavigation = launcherController.isActive
        defer { keepLauncherVisibleAcrossTargetNavigation = previous }
        block()
    }

}
