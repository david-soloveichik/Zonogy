import AppKit

/// Defines the operations the floating-zone coordinator can call back into.
protocol FloatingZoneCoordinatorHost: AnyObject {
    var windowController: WindowController { get }
    var targetedZoneManager: TargetedZoneManager { get }
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
    func addZone(on screenId: CGDirectDisplayID, side: ZoneSide?, announce: Bool, promoteFloatingOccupant: Bool) -> Zone?
    func addZoneIndicatorHitAreas() -> [AddZonePillKey: CGRect]
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
    /// Per-window remembered floating-zone size. Updated whenever the user resizes a window while
    /// it is a floating-zone occupant, and cleared only when the window is destroyed. Applied on
    /// subsequent placements into any floating zone so a window returns to its last floating size.
    private var rememberedSizesByWindowId: [Int: CGSize] = [:]

    init(host: FloatingZoneCoordinatorHost, displacedWindowCoordinator: DisplacedWindowCoordinator) {
        self.host = host
        self.displacedWindowCoordinator = displacedWindowCoordinator
    }

    func rememberSize(for windowId: Int, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        rememberedSizesByWindowId[windowId] = size
        Logger.debug("FloatingZoneSize: remembered size \(size) for window \(windowId)")
    }

    func clearRememberedSize(for windowId: Int) {
        if rememberedSizesByWindowId.removeValue(forKey: windowId) != nil {
            Logger.debug("FloatingZoneSize: cleared remembered size for window \(windowId)")
        }
    }

    private func rememberedSize(for windowId: Int) -> CGSize? {
        guard let size = rememberedSizesByWindowId[windowId],
              size.width > 0, size.height > 0 else {
            return nil
        }
        return size
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

    /// Defaults the displacement strategy to `.synchronous` (Zonogy-initiated swap, no
    /// app-launch unminimize storm to fight). Callers that propagate from `placeNewWindow`
    /// (any "a window arrived" placement targeting the floating zone) pass `.deferred` to
    /// avoid an infinite minimize/unminimize loop with apps restoring their session windows.
    func assign(
        _ managed: ManagedWindow,
        to screenId: CGDirectDisplayID,
        centerWindow: Bool = true,
        reason: String,
        displacement: DisplacementStrategy = .synchronous
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
        let finalizeDisplaced: (ManagedWindow) -> Void = { displaced in
            switch displacement {
            case .synchronous:
                host.minimizeWindowProgrammatically(displaced, reason: displacedMinimizeReason)
                Logger.debug(
                    "Floating zone minimized displaced occupant \(displaced.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(displacedMinimizeReason))"
                )
            case .deferred:
                host.queueDeferredMinimization(windowId: displaced.windowId, reason: displacedMinimizeReason)
                Logger.debug(
                    "Floating zone queued deferred minimization for displaced occupant \(displaced.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(displacedMinimizeReason))"
                )
            }
        }

        SingleOccupantReplacement.replaceIfNeeded(
            existingWindowId: occupants[screenId],
            incomingWindowId: managed.windowId,
            lookupWindow: { host.windowController.window(withId: $0) },
            evictExistingWindowId: { occupantId in
                host.clearFloatingZoneProtection(windowId: occupantId)
                occupants.removeValue(forKey: screenId)
            },
            clearDisplacedAssignment: { host.clearManagedWindowZone($0) },
            // For `.synchronous`: AX kAXMinimized's brief flash-to-key on the displaced
            // window happens before the incoming window's frame writes/raise (because
            // `SingleOccupantReplacement` runs `finalize` before `assignIncoming`), so
            // the flash is invisible. For `.deferred`: the minimize is queued so any
            // ongoing external unminimize burst can drain before it lands (avoiding the
            // infinite ping-pong loop with apps restoring their session windows).
            finalizeDisplaced: finalizeDisplaced,
            assignIncoming: {
                occupants[screenId] = managed.windowId
                managed.isInFloatingZone = true
                host.setManagedWindow(managed, screenId: screenId, zoneIndex: nil)

                var committedSize: CGSize?
                if centerWindow,
                   let descriptor = host.descriptor(for: screenId) {
                    let frame = placementFrame(for: managed, on: descriptor)
                    host.windowController.showWindow(managed, at: frame, on: descriptor)
                    committedSize = frame.size
                } else {
                    let actual = managed.actualFrame.size
                    if actual.width > 0, actual.height > 0 {
                        committedSize = actual
                    }
                }

                // Seed the remembered size on first placement so subsequent re-entries
                // (after tiling-zone excursions) restore this floating-zone size instead
                // of the window's post-excursion actualFrame.
                if let committedSize, rememberedSize(for: managed.windowId) == nil {
                    rememberSize(for: managed.windowId, size: committedSize)
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

            if handleProtectedReactivate(window: window) {
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

            if handleProtectedReactivate(window: window) {
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
        hoveredAddZonePill: AddZonePillKey?,
        hoveredFloatingScreenId: CGDirectDisplayID?,
        finalCursorPoint: CGPoint?
    ) {
        guard let host,
              let managed = host.windowController.window(withId: windowId) else {
            return
        }

        let addZonePill = hoveredAddZonePill ??
            addZoneDropTarget(for: finalCursorPoint)

        if let addZonePill,
           let newZone = host.addZone(on: addZonePill.screenId, side: addZonePill.side, announce: false, promoteFloatingOccupant: false) {
            clear(windowId: windowId, minimize: false, reason: "floating-drop-add-zone")
            if let result = host.windowPlacementManager.assignWindowFromDrag(
                managed,
                to: ZoneKey(screenId: addZonePill.screenId, index: newZone.index)
            ) {
                displacedWindowCoordinator.resolve(
                    result.displacedWindow,
                    preferredScreenId: addZonePill.screenId,
                    disposition: .reassign
                )
            }
            return
        }

        if let hoveredFloatingScreenId,
           handleFloatingIndicatorDrop(managed: managed, destinationScreenId: hoveredFloatingScreenId) {
            return
        }

        if handleCrossScreenFloatingDrop(managed: managed, finalFrame: finalFrame) {
            return
        }

        // Otherwise, leaving the floating zone simply keeps the window floating.
    }

    private func handleFloatingIndicatorDrop(managed: ManagedWindow, destinationScreenId: CGDirectDisplayID) -> Bool {
        guard let originScreenId = occupants.first(where: { $0.value == managed.windowId })?.key else {
            return false
        }

        if destinationScreenId == originScreenId {
            return true
        }

        return moveFloatingWindow(managed, originScreenId: originScreenId, destinationScreenId: destinationScreenId)
    }

    private func handleCrossScreenFloatingDrop(managed: ManagedWindow, finalFrame: CGRect) -> Bool {
        guard let host,
              let originScreenId = occupants.first(where: { $0.value == managed.windowId })?.key,
              let destinationScreenId = host.screenIdForAccessibilityFrame(finalFrame) else {
            return false
        }

        if destinationScreenId == originScreenId {
            return false
        }

        return moveFloatingWindow(managed, originScreenId: originScreenId, destinationScreenId: destinationScreenId)
    }

    private func moveFloatingWindow(
        _ managed: ManagedWindow,
        originScreenId: CGDirectDisplayID,
        destinationScreenId: CGDirectDisplayID
    ) -> Bool {
        guard let host else {
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
    
    private func addZoneDropTarget(for cursorPoint: CGPoint?) -> AddZonePillKey? {
        guard let host, let cursorPoint else { return nil }
        let hitAreas = host.addZoneIndicatorHitAreas()
        for (pill, frame) in hitAreas where frame.contains(cursorPoint) {
            return pill
        }
        return nil
    }

    private func placementFrame(for managed: ManagedWindow, on descriptor: ScreenDescriptor) -> CGRect {
        let bounds = descriptor.visibleScreenBounds.standardized
        let minWidth = bounds.width / 3
        let maxWidth = bounds.width * 0.8
        let minHeight = bounds.height / 3
        let maxHeight = bounds.height * 0.8

        var width: CGFloat
        var height: CGFloat
        if let remembered = rememberedSize(for: managed.windowId) {
            width = remembered.width
            height = remembered.height
        } else if managed.actualFrame.width > 0, managed.actualFrame.height > 0 {
            width = managed.actualFrame.width
            height = managed.actualFrame.height
        } else {
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

    /// If `window` is under active floating-zone protection, re-raise it (unless the
    /// user has just minimized it) and return `true` so the caller skips further
    /// focus/activation handling. Returns `false` when the window is not protected.
    private func handleProtectedReactivate(window: ManagedWindow) -> Bool {
        guard let host, host.shouldProtectFloatingZoneOccupant(windowId: window.windowId) else {
            return false
        }
        if window.isMinimizedPerAccessibility {
            Logger.debug("Floating zone protection skipped reactivate for minimized window \(window.windowId)")
            return true
        }
        host.activateFloatingZoneWindow(window, reason: "protection-reactivate")
        return true
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
