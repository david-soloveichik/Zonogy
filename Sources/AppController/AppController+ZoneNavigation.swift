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
                    windowPlacementManager.handleWindowAfterZoneRemoval(managed, preferredScreenId: screenId)
                }
            }

            placeholderCoordinator.clearPlaceholdersForScreen(screenId)

            syncWindowsToZones()
            activeFitRefreshAfterZoneTopologyChange(reason: "reset-to-one-zone")
        } else {
            Logger.debug("Clear/reset zones (\(reason)): minimizing all windows on screen \(screenIndex)")

            // Collect all windows to minimize (floating zone + tiled zones)
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

            // Suppress all miniaturize events at once, then minimize all in parallel
            let minimizedWindowIds = windowsToMinimize.map { $0.windowId }
            if !minimizedWindowIds.isEmpty {
                suppressNextEvents(for: minimizedWindowIds, events: [.miniaturized], reason: "clear-zones-shortcut")
            }
            for managed in windowsToMinimize {
                windowController.minimizeWindow(managed)
            }

            // Remove from zones after all minimizes are issued
            for managed in windowsToMinimize {
                removeWindowFromAllZones(windowId: managed.windowId, reason: "clear-zones-shortcut", retarget: false)
            }

            Logger.debug("Clear/reset zones (\(reason)): minimized \(minimizedWindowIds.count) window(s) on screen \(screenIndex)")
            syncWindowsToZones()

            // Verify minimization actually took effect. Some apps like Word seem to sometimes
            // auto-activate sibling windows when one is minimized, which can cancel a rapid-fire minimize.
            for windowId in minimizedWindowIds {
                scheduleMinimizeVerification(
                    windowId: windowId,
                    emptiedZoneKey: nil,
                    minimizeReason: "clear-zones-shortcut",
                    cleanupReason: "clear-zones-shortcut",
                    manualResizeState: ManualResizeCleanupState(wasDetached: false, rememberedSize: nil)
                )
            }
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
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
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

            // Issue AX minimize and let the notification handler do zone cleanup/retarget.
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

    /// Target the floating zone, preferring the screen of the currently targeted normal zone
    internal func targetFloatingZone() {
        guard let targetedZone = targetedZoneManager.targetedZoneKey else {
            Logger.debug("Target floating zone: normal zone not targeted; shortcut ignored")
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
        Logger.debug("Target floating zone: setting floating zone on screen \(screenIndex) as target")
        targetedZoneManager.setFloatingTarget(on: preferredScreenId, reason: "shortcut-target-floating")
    }

    /// Target tiling zone: from floating zone to normal zone on same screen
    internal func targetTilingZone() {
        guard let targetedFloatingScreenId = targetedZoneManager.targetedFloatingScreenId else {
            Logger.debug("Target tiling zone: floating zone not targeted, doing nothing")
            return
        }

        guard let context = screenContexts[targetedFloatingScreenId] else {
            Logger.debug("Target tiling zone: no context for floating zone screen")
            return
        }

        let zones = context.zoneController.allZones

        // Prefer empty tiling zone with lowest index
        let emptyZones = zones.filter { $0.isEmpty }.sorted { $0.index < $1.index }
        if let firstEmptyZone = emptyZones.first {
            let zoneKey = ZoneKey(screenId: targetedFloatingScreenId, index: firstEmptyZone.index)
            Logger.debug("Target tiling zone: targeting empty zone \(firstEmptyZone.index) on screen \(screenContextStore.loggingIndex(for: targetedFloatingScreenId))")
            targetedZoneManager.setTargetedZone(zoneKey, reason: "shortcut-target-tiling-zone")
            return
        }

        // If no empty zone, target filled zone with highest index
        let filledZones = zones.filter { !$0.isEmpty }.sorted { $0.index > $1.index }
        if let firstFilledZone = filledZones.first {
            let zoneKey = ZoneKey(screenId: targetedFloatingScreenId, index: firstFilledZone.index)
            Logger.debug("Target tiling zone: targeting filled zone \(firstFilledZone.index) on screen \(screenContextStore.loggingIndex(for: targetedFloatingScreenId))")
            targetedZoneManager.setTargetedZone(zoneKey, reason: "shortcut-target-tiling-zone")
            return
        }

        Logger.debug("Target tiling zone: no zones available on screen")
    }

    /// Navigate left: between zones or screens
    internal func navigateLeft() {
        // If floating zone is targeted, go to floating zone on screen to the left
        if let targetedFloatingScreenId = targetedZoneManager.targetedFloatingScreenId {
            navigateFloatingZoneLeft(from: targetedFloatingScreenId)
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
        // If floating zone is targeted, go to floating zone on screen to the right
        if let targetedFloatingScreenId = targetedZoneManager.targetedFloatingScreenId {
            navigateFloatingZoneRight(from: targetedFloatingScreenId)
            return
        }

        // If normal zone is targeted, navigate to higher index or next screen
        if let targetedKey = targetedZoneManager.targetedZoneKey {
            navigateNormalZoneRight(from: targetedKey)
            return
        }

        Logger.debug("Navigate right: no zone targeted")
    }

    private func navigateFloatingZoneLeft(from currentScreenId: CGDirectDisplayID) {
        let screens = screenOrderLeftToRight
        guard let currentIndex = screens.firstIndex(of: currentScreenId), currentIndex > 0 else {
            Logger.debug("Navigate left (floating): already at leftmost screen")
            return
        }

        let leftScreenId = screens[currentIndex - 1]
        Logger.debug("Navigate left (floating): targeting floating zone on screen \(screenContextStore.loggingIndex(for: leftScreenId))")
        targetedZoneManager.setFloatingTarget(on: leftScreenId, reason: "shortcut-navigate-left-floating")
    }

    private func navigateFloatingZoneRight(from currentScreenId: CGDirectDisplayID) {
        let screens = screenOrderLeftToRight
        guard let currentIndex = screens.firstIndex(of: currentScreenId), currentIndex < screens.count - 1 else {
            Logger.debug("Navigate right (floating): already at rightmost screen")
            return
        }

        let rightScreenId = screens[currentIndex + 1]
        Logger.debug("Navigate right (floating): targeting floating zone on screen \(screenContextStore.loggingIndex(for: rightScreenId))")
        targetedZoneManager.setFloatingTarget(on: rightScreenId, reason: "shortcut-navigate-right-floating")
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
}
