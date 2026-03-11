import AppKit

/// Defines the operations the floating-zone coordinator can call back into.
protocol FloatingZoneCoordinatorHost: AnyObject {
    var windowController: WindowController { get }
    var targetedZoneManager: TargetedZoneManager { get }
    var targetingMode: TargetingMode { get }
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    var screenContextStore: ScreenContextStore { get }
    var windowPlacementManager: WindowPlacementManager { get }
    func minimizeWindowProgrammatically(_ managed: ManagedWindow, reason: String)
    func queueDeferredMinimization(windowId: Int, reason: String)
    func cancelPendingMinimization(windowId: Int)

    func refreshResizeHandles()
    func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?
    func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?)
    func clearManagedWindowZone(_ managed: ManagedWindow)
    func addZone(on screenId: CGDirectDisplayID, announce: Bool, promoteFloatingOccupant: Bool) -> Zone?
    func addZoneIndicatorHitAreas() -> [CGDirectDisplayID: CGRect]
    func refreshIndicators()
    func updateFloatingIndicatorHighlight(screenId: CGDirectDisplayID?)
    func activeScreenId() -> CGDirectDisplayID
    func detectScreenId(for window: ManagedWindow) -> CGDirectDisplayID?
    func screenIdForAccessibilityFrame(_ frame: CGRect) -> CGDirectDisplayID?
    func shouldProtectFloatingZoneOccupant(windowId: Int) -> Bool
    func scheduleFloatingZoneProtection(windowId: Int)
    func clearFloatingZoneProtection(windowId: Int)
    func activateFloatingZoneWindow(_ managed: ManagedWindow, reason: String)
}

/// Centralizes floating-zone occupant bookkeeping, placement, targeting, and occlusion checks.
final class FloatingZoneCoordinator {
    private struct TiledFocusContext {
        let window: ManagedWindow
        let pid: pid_t
        let screenId: CGDirectDisplayID?
    }

    weak var host: FloatingZoneCoordinatorHost?
    private let displacedWindowCoordinator: DisplacedWindowCoordinator
    private(set) var occupants: [CGDirectDisplayID: Int] = [:]

    init(host: FloatingZoneCoordinatorHost, displacedWindowCoordinator: DisplacedWindowCoordinator) {
        self.host = host
        self.displacedWindowCoordinator = displacedWindowCoordinator
    }

    func occupant(on screenId: CGDirectDisplayID) -> ManagedWindow? {
        guard let host, let windowId = occupants[screenId] else {
            return nil
        }
        return host.windowController.window(withId: windowId)
    }

    func isWindowInFloatingZone(_ windowId: Int) -> Bool {
        return occupants.values.contains(windowId)
    }

    func assign(
        _ managed: ManagedWindow,
        to screenId: CGDirectDisplayID,
        centerWindow: Bool = true,
        reason: String
    ) {
        guard let host else { return }

        host.cancelPendingMinimization(windowId: managed.windowId)

        if isWindowInFloatingZone(managed.windowId),
           let existingScreenId = occupants.first(where: { $0.value == managed.windowId })?.key {
            // Reassigning a window that's already in a floating zone (e.g. screen migration).
            // Avoid a full clear cycle so we don't accidentally change targeting state.
            host.clearFloatingZoneProtection(windowId: managed.windowId)
            occupants.removeValue(forKey: existingScreenId)
        }

        let displacedMinimizeReason = "\(reason)-displaced"

        SingleOccupantReplacement.replaceIfNeeded(
            existingWindowId: occupants[screenId],
            incomingWindowId: managed.windowId,
            lookupWindow: { host.windowController.window(withId: $0) },
            evictExistingWindowId: { occupantId in
                host.clearFloatingZoneProtection(windowId: occupantId)
                occupants.removeValue(forKey: screenId)
            },
            clearDisplacedAssignment: { host.clearManagedWindowZone($0) },
            finalizeDisplaced: { displaced in
                host.queueDeferredMinimization(windowId: displaced.windowId, reason: displacedMinimizeReason)
                Logger.debug(
                    "Floating zone queued minimization for occupant \(displaced.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(displacedMinimizeReason))"
                )
            },
            assignIncoming: {
                occupants[screenId] = managed.windowId
                managed.isInFloatingZone = true
                host.setManagedWindow(managed, screenId: screenId, zoneIndex: nil)

                if centerWindow,
                   let descriptor = host.descriptor(for: screenId) {
                    let frame = placementFrame(for: managed, on: descriptor)
                    host.windowController.showWindow(managed, at: frame, on: descriptor)
                }
            },
            afterAssignIncoming: {
                host.activateFloatingZoneWindow(managed, reason: reason)
                host.scheduleFloatingZoneProtection(windowId: managed.windowId)
            }
        )

        Logger.debug("Assigned window \(managed.windowId) to floating zone on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
        host.refreshIndicators()
        host.refreshResizeHandles()
    }

    func minimizeOccupant(on screenId: CGDirectDisplayID, reason: String) {
        guard let host,
              let occupant = occupant(on: screenId) else {
            return
        }
        host.clearFloatingZoneProtection(windowId: occupant.windowId)
        occupant.isInFloatingZone = false
        occupants.removeValue(forKey: screenId)
        host.clearManagedWindowZone(occupant)
        host.queueDeferredMinimization(windowId: occupant.windowId, reason: reason)
        Logger.debug(
            "Floating zone queued minimization for occupant \(occupant.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))"
        )
        host.refreshIndicators()
        host.refreshResizeHandles()
    }

    func clear(windowId: Int, minimize: Bool, reason: String) {
        guard let host,
              let entry = occupants.first(where: { $0.value == windowId }) else {
            return
        }
        host.clearFloatingZoneProtection(windowId: windowId)
        if let window = host.windowController.window(withId: windowId) {
            window.isInFloatingZone = false
        }
        occupants.removeValue(forKey: entry.key)
        Logger.debug("Cleared floating zone occupant \(windowId) on screen \(host.screenContextStore.loggingIndex(for: entry.key)) (reason: \(reason))")
        if minimize, let window = host.windowController.window(withId: windowId) {
            host.clearManagedWindowZone(window)
            host.minimizeWindowProgrammatically(window, reason: reason)
        }
        host.refreshIndicators()
        host.refreshResizeHandles()
    }

    func handleFocusChange(pid: pid_t, focusedWindowId: Int?) {
        guard let host,
              let focusContext = tiledFocusContext(pid: pid, focusedWindowId: focusedWindowId) else {
            return
        }

        let entries = occupants
        let focusScreenId = focusContext.screenId
        for (screenId, occupantId) in entries {
            if let focusScreenId, focusScreenId != screenId {
                continue
            }
            guard let window = host.windowController.window(withId: occupantId) else {
                occupants.removeValue(forKey: screenId)
                continue
            }
            let occupantPid = window.backing.pid

            if host.shouldProtectFloatingZoneOccupant(windowId: occupantId) {
                host.activateFloatingZoneWindow(window, reason: "protection-reactivate")
                continue
            }

            if occupantPid == focusContext.pid {
                if focusContext.window.windowId == occupantId {
                    continue
                }
                queueConditionalMinimizeOccupant(on: screenId, reason: "focus-shift-same-app")
            } else {
                queueConditionalMinimizeOccupant(on: screenId, reason: "focus-shift-other-app")
            }
        }
    }

    func handleActivationChange(focusedPid: pid_t?, reason: String) {
        guard let host,
              let focusedPid,
              let focusContext = tiledFocusContext(pid: focusedPid, focusedWindowId: nil) else {
            return
        }

        let entries = occupants
        let focusScreenId = focusContext.screenId
        for (screenId, occupantId) in entries {
            if let focusScreenId, focusScreenId != screenId {
                continue
            }
            guard let window = host.windowController.window(withId: occupantId) else {
                occupants.removeValue(forKey: screenId)
                continue
            }
            let occupantPid = window.backing.pid

            if host.shouldProtectFloatingZoneOccupant(windowId: occupantId) {
                host.activateFloatingZoneWindow(window, reason: "protection-reactivate")
                continue
            }

            if occupantPid == focusContext.pid,
               focusContext.window.windowId == occupantId {
                continue
            }

            queueConditionalMinimizeOccupant(on: screenId, reason: reason)
        }
    }

    /// Prepare host/delegate state right before deferred minimization executes.
    /// For focus-driven floating-zone minimization, we only proceed if the window is
    /// still the floating occupant at flush time.
    func prepareForDeferredMinimization(windowId: Int, reason: String) -> Bool {
        guard let host else { return false }

        guard isOcclusionBasedFloatingMinimizationReason(reason) else {
            return true
        }

        guard let screenId = occupants.first(where: { $0.value == windowId })?.key else {
            Logger.debug(
                "Floating zone deferred minimization skipped for window \(windowId): no longer floating occupant (reason: \(reason))"
            )
            return false
        }

        guard isFloatingZoneOccupantOccluded(on: screenId, occupantWindowId: windowId) else {
            Logger.debug(
                "Floating zone deferred minimization skipped for window \(windowId): not occluded (reason: \(reason))"
            )
            return false
        }

        host.clearFloatingZoneProtection(windowId: windowId)
        occupants.removeValue(forKey: screenId)

        if let occupant = host.windowController.window(withId: windowId) {
            occupant.isInFloatingZone = false
            host.clearManagedWindowZone(occupant)
        }

        host.refreshIndicators()
        host.refreshResizeHandles()
        return true
    }

    func finalizeFloatingDrop(
        windowId: Int,
        _ finalFrame: CGRect,
        hoveredAddZoneScreenId: CGDirectDisplayID?,
        finalCursorPoint: CGPoint?
    ) {
        guard let host,
              let managed = host.windowController.window(withId: windowId) else {
            return
        }

        let addZoneScreenId = hoveredAddZoneScreenId ??
            addZoneDropTarget(for: finalCursorPoint)

        if let addZoneScreenId,
           let newZone = host.addZone(on: addZoneScreenId, announce: false, promoteFloatingOccupant: false) {
            clear(windowId: windowId, minimize: false, reason: "floating-drop-add-zone")
            if let result = host.windowPlacementManager.assignWindowFromDrag(
                managed,
                to: ZoneKey(screenId: addZoneScreenId, index: newZone.index)
            ) {
                displacedWindowCoordinator.resolve(
                    result.displacedWindow,
                    preferredScreenId: addZoneScreenId,
                    disposition: .reassign
                )
            }
            return
        }

        if handleCrossScreenFloatingDrop(managed: managed, finalFrame: finalFrame) {
            return
        }

        // Otherwise, leaving the floating zone simply keeps the window floating.
    }

    private func handleCrossScreenFloatingDrop(managed: ManagedWindow, finalFrame: CGRect) -> Bool {
        guard let host,
              let originScreenId = occupants.first(where: { $0.value == managed.windowId })?.key,
              let destinationScreenId = host.screenIdForAccessibilityFrame(finalFrame),
              destinationScreenId != originScreenId else {
            return false
        }

        let displacedWindow = occupants[destinationScreenId].flatMap { host.windowController.window(withId: $0) }
        let originIndex = host.screenContextStore.loggingIndex(for: originScreenId)
        let destinationIndex = host.screenContextStore.loggingIndex(for: destinationScreenId)

        // Bookkeeping: move the dragged window to the destination screen's floating zone.
        occupants.removeValue(forKey: originScreenId)
        occupants[destinationScreenId] = managed.windowId
        host.setManagedWindow(managed, screenId: destinationScreenId, zoneIndex: nil)

        // If the destination already had a floating occupant, swap it back to the origin screen.
        if let displacedWindow {
            occupants[originScreenId] = displacedWindow.windowId
            host.setManagedWindow(displacedWindow, screenId: originScreenId, zoneIndex: nil)

            if let descriptor = host.descriptor(for: originScreenId) {
                let placementFrame = placementFrame(for: displacedWindow, on: descriptor)
                host.windowController.showWindow(displacedWindow, at: placementFrame, on: descriptor)
            }

            Logger.debug(
                "Swapped floating zone occupants: window \(managed.windowId) -> screen \(destinationIndex), " +
                    "window \(displacedWindow.windowId) -> screen \(originIndex)"
            )
        } else {
            Logger.debug("Moved floating zone window \(managed.windowId) from screen \(originIndex) to screen \(destinationIndex)")
        }

        host.refreshIndicators()
        host.refreshResizeHandles()
        return true
    }
    
    private func addZoneDropTarget(for cursorPoint: CGPoint?) -> CGDirectDisplayID? {
        guard let host, let cursorPoint else { return nil }
        let hitAreas = host.addZoneIndicatorHitAreas()
        for (screenId, frame) in hitAreas where frame.contains(cursorPoint) {
            return screenId
        }
        return nil
    }

    private func placementFrame(for managed: ManagedWindow, on descriptor: ScreenDescriptor) -> CGRect {
        let bounds = descriptor.visibleScreenBounds.standardized
        let minWidth = bounds.width / 3
        let maxWidth = bounds.width * 0.8
        let minHeight = bounds.height / 3
        let maxHeight = bounds.height * 0.8

        var width = managed.actualFrame.width
        var height = managed.actualFrame.height

        if width <= 0 || height <= 0 {
            width = (bounds.width * 0.55).rounded()
            height = (bounds.height * 0.55).rounded()
        }

        width = min(max(width, minWidth), maxWidth)
        height = min(max(height, minHeight), maxHeight)

        var originX = (bounds.midX - width / 2).rounded()
        var originY = (bounds.midY - height / 2).rounded()
        originX = max(bounds.minX, min(originX, bounds.maxX - width))
        originY = max(bounds.minY, min(originY, bounds.maxY - height))
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Compute the placement frame for a window in the floating zone without actually placing it.
    /// Used for pre-positioning minimized windows before unminimizing.
    func computePlacementFrame(for managed: ManagedWindow, on screenId: CGDirectDisplayID) -> CGRect? {
        guard let descriptor = host?.descriptor(for: screenId) else { return nil }
        return placementFrame(for: managed, on: descriptor)
    }

    func hasAvailableTiledZone() -> Bool {
        guard let host else { return false }
        return emptyZoneCount(in: host.screenContexts) > 0
    }

    private func emptyZoneCount(in contexts: [CGDirectDisplayID: ScreenContext]) -> Int {
        var count = 0
        for context in contexts.values {
            for zone in context.zoneController.allZones where zone.isEmpty {
                count += 1
            }
        }
        return count
    }

    private func tiledFocusContext(pid: pid_t, focusedWindowId: Int?) -> TiledFocusContext? {
        guard let host,
              let managed = resolvedFocusedWindow(host: host, pid: pid, focusedWindowId: focusedWindowId),
              isTiledWindow(managed) else {
            return nil
        }

        let resolvedPid = managed.backing.pid
        let screenId = managed.screenDisplayId ?? host.detectScreenId(for: managed)
        return TiledFocusContext(window: managed, pid: resolvedPid, screenId: screenId)
    }

    private func resolvedFocusedWindow(
        host: FloatingZoneCoordinatorHost,
        pid: pid_t,
        focusedWindowId: Int?
    ) -> ManagedWindow? {
        if let focusedWindowId,
           let window = host.windowController.window(withId: focusedWindowId) {
            return window
        }
        return host.windowController.focusedWindowIfTracked(pid: pid)
    }

    private func isTiledWindow(_ window: ManagedWindow) -> Bool {
        return window.zoneIndex != nil
    }

    private func queueConditionalMinimizeOccupant(on screenId: CGDirectDisplayID, reason: String) {
        guard let host,
              let occupant = occupant(on: screenId) else {
            return
        }
        host.queueDeferredMinimization(windowId: occupant.windowId, reason: reason)
        Logger.debug(
            "Floating zone queued conditional minimization for occupant \(occupant.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))"
        )
    }

    private func isOcclusionBasedFloatingMinimizationReason(_ reason: String) -> Bool {
        reason.hasPrefix("focus-shift-") ||
            reason == "workspace-activate" ||
            reason.hasPrefix("occlusion-check-")
    }

    private func isFloatingZoneOccupantOccluded(on screenId: CGDirectDisplayID, occupantWindowId: Int) -> Bool {
        guard let host,
              let occupant = host.windowController.window(withId: occupantWindowId),
              let occupantFrame = host.windowController.actualFrameInAccessibilityCoordinates(for: occupant),
              let context = host.screenContexts[screenId] else {
            return false
        }

        var occluders: [OcclusionWindow] = []
        occluders.reserveCapacity(context.zoneController.allZones.count + 4)

        // Occupied tiling zones occlude based on their zone frames, not the window's
        // live frame. This keeps ActiveFit reveal spillover from enlarging the occlusion area.
        for zone in context.zoneController.allZones {
            guard let windowId = zone.occupantWindowId,
                  windowId != occupantWindowId,
                  let managed = host.windowController.window(withId: windowId) else {
                continue
            }
            let zoneFrame = context.descriptor.screenToAccessibility(zone.frame)
            occluders.append(OcclusionWindow(cgWindowId: managed.backing.cgWindowId, frame: zoneFrame))
        }

        // Fast path: if nothing even overlaps geometrically, occlusion is impossible.
        guard occluders.contains(where: {
            FloatingZoneOverlapPolicy.overlapsZoneFrame(
                floatingFrame: occupantFrame,
                zoneFrame: $0.frame
            )
        }) else {
            return false
        }

        guard let zOrder = WindowServerWindowList.onScreenWindowNumbersFrontToBack() else {
            return false
        }

        let target = OcclusionWindow(cgWindowId: occupant.backing.cgWindowId, frame: occupantFrame)
        return WindowOcclusionPolicy.isOccluded(
            target: target,
            occluders: occluders,
            zOrderFrontToBack: zOrder
        )
    }

}
