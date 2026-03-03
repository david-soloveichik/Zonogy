import AppKit

/// Defines the operations the temporary-zone coordinator can call back into.
protocol TemporaryZoneCoordinatorHost: AnyObject {
    var windowController: WindowController { get }
    var targetedZoneManager: TargetedZoneManager { get }
    var targetingMode: TargetingMode { get }
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    var screenContextStore: ScreenContextStore { get }
    func placeholderOccluders(on screenId: CGDirectDisplayID) -> [OcclusionWindow]
    var windowPlacementManager: WindowPlacementManager { get }
    func minimizeWindowProgrammatically(_ managed: ManagedWindow, reason: String)
    func queueDeferredMinimization(windowId: Int, reason: String)
    func cancelPendingMinimization(windowId: Int)

    func refreshResizeHandles()
    func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?
    func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?)
    func clearManagedWindowZone(_ managed: ManagedWindow)
    func addZone(on screenId: CGDirectDisplayID, announce: Bool, promoteTemporaryOccupant: Bool) -> Zone?
    func addZoneIndicatorHitAreas() -> [CGDirectDisplayID: CGRect]
    func refreshIndicators()
    func updateTemporaryIndicatorHighlight(screenId: CGDirectDisplayID?)
    func activeScreenId() -> CGDirectDisplayID
    func detectScreenId(for window: ManagedWindow) -> CGDirectDisplayID?
    func screenIdForAccessibilityFrame(_ frame: CGRect) -> CGDirectDisplayID?
    func shouldProtectTemporaryZoneOccupant(windowId: Int) -> Bool
    func scheduleTemporaryZoneProtection(windowId: Int)
    func clearTemporaryZoneProtection(windowId: Int)
    func activateTemporaryZoneWindow(_ managed: ManagedWindow, reason: String)
}

/// Centralizes temporary-zone occupant bookkeeping, placement, and targeting.
final class TemporaryZoneCoordinator {
    struct RecallSnapshot: Equatable {
        let windowId: Int
        /// Last known frame of the window while it occupied this screen's temporary zone.
        /// Expressed in screen-local coordinates for that screen.
        let screenFrame: CGRect?
    }

    private struct TiledFocusContext {
        let window: ManagedWindow
        let pid: pid_t
        let screenId: CGDirectDisplayID?
    }

    weak var host: TemporaryZoneCoordinatorHost?
    private let displacedWindowCoordinator: DisplacedWindowCoordinator
    private(set) var occupants: [CGDirectDisplayID: Int] = [:]
    private var mostRecentOccupantByScreenId: [CGDirectDisplayID: RecallSnapshot] = [:]

    init(host: TemporaryZoneCoordinatorHost, displacedWindowCoordinator: DisplacedWindowCoordinator) {
        self.host = host
        self.displacedWindowCoordinator = displacedWindowCoordinator
    }

    func occupant(on screenId: CGDirectDisplayID) -> ManagedWindow? {
        guard let host, let windowId = occupants[screenId] else {
            return nil
        }
        return host.windowController.window(withId: windowId)
    }

    func mostRecentOccupantSnapshot(on screenId: CGDirectDisplayID) -> RecallSnapshot? {
        mostRecentOccupantByScreenId[screenId]
    }

    func clearMostRecentOccupantSnapshot(on screenId: CGDirectDisplayID) {
        mostRecentOccupantByScreenId.removeValue(forKey: screenId)
    }

    func isWindowInTemporaryZone(_ windowId: Int) -> Bool {
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

        if isWindowInTemporaryZone(managed.windowId),
           let existingScreenId = occupants.first(where: { $0.value == managed.windowId })?.key {
            // Reassigning a window that's already in a temporary zone (e.g. screen migration).
            // Avoid a full clear cycle so we don't accidentally change targeting state.
            if existingScreenId != screenId {
                updateMostRecentOccupantSnapshot(
                    screenId: existingScreenId,
                    windowId: managed.windowId,
                    managed: managed,
                    reason: "\(reason)-reassign"
                )
            }
            host.clearTemporaryZoneProtection(windowId: managed.windowId)
            occupants.removeValue(forKey: existingScreenId)
        }

        let displacedMinimizeReason = "\(reason)-displaced"

        SingleOccupantReplacement.replaceIfNeeded(
            existingWindowId: occupants[screenId],
            incomingWindowId: managed.windowId,
            lookupWindow: { host.windowController.window(withId: $0) },
            evictExistingWindowId: { occupantId in
                host.clearTemporaryZoneProtection(windowId: occupantId)
                occupants.removeValue(forKey: screenId)
            },
            clearDisplacedAssignment: { host.clearManagedWindowZone($0) },
            finalizeDisplaced: { displaced in
                host.queueDeferredMinimization(windowId: displaced.windowId, reason: displacedMinimizeReason)
                Logger.debug(
                    "Temporary zone queued minimization for occupant \(displaced.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(displacedMinimizeReason))"
                )
            },
            assignIncoming: {
                occupants[screenId] = managed.windowId
                managed.isInTemporaryZone = true
                host.setManagedWindow(managed, screenId: screenId, zoneIndex: nil)

                if centerWindow,
                   let descriptor = host.descriptor(for: screenId) {
                    let frame = placementFrame(for: managed, on: descriptor)
                    host.windowController.showWindow(managed, at: frame, on: descriptor)
                }
            },
            afterAssignIncoming: {
                host.activateTemporaryZoneWindow(managed, reason: reason)
                host.scheduleTemporaryZoneProtection(windowId: managed.windowId)
            }
        )

        Logger.debug("Assigned window \(managed.windowId) to temporary zone on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
        host.refreshIndicators()
        host.refreshResizeHandles()
    }

    func minimizeOccupant(on screenId: CGDirectDisplayID, reason: String) {
        guard let host,
              let occupant = occupant(on: screenId) else {
            return
        }
        updateMostRecentOccupantSnapshot(
            screenId: screenId,
            windowId: occupant.windowId,
            managed: occupant,
            reason: reason
        )
        host.clearTemporaryZoneProtection(windowId: occupant.windowId)
        occupant.isInTemporaryZone = false
        occupants.removeValue(forKey: screenId)
        host.clearManagedWindowZone(occupant)
        host.queueDeferredMinimization(windowId: occupant.windowId, reason: reason)
        Logger.debug(
            "Temporary zone queued minimization for occupant \(occupant.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))"
        )
        host.refreshIndicators()
        host.refreshResizeHandles()
    }

    func clear(windowId: Int, minimize: Bool, reason: String) {
        guard let host,
              let entry = occupants.first(where: { $0.value == windowId }) else {
            return
        }
        let screenId = entry.key
        updateMostRecentOccupantSnapshot(
            screenId: screenId,
            windowId: windowId,
            managed: host.windowController.window(withId: windowId),
            reason: reason
        )
        host.clearTemporaryZoneProtection(windowId: windowId)
        if let window = host.windowController.window(withId: windowId) {
            window.isInTemporaryZone = false
        }
        occupants.removeValue(forKey: entry.key)
        Logger.debug("Cleared temporary zone occupant \(windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
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
                updateMostRecentOccupantSnapshot(
                    screenId: screenId,
                    windowId: occupantId,
                    managed: nil,
                    reason: "focus-change-missing-occupant"
                )
                occupants.removeValue(forKey: screenId)
                continue
            }
            let occupantPid = window.backing.pid

            if host.shouldProtectTemporaryZoneOccupant(windowId: occupantId) {
                host.activateTemporaryZoneWindow(window, reason: "protection-reactivate")
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
                updateMostRecentOccupantSnapshot(
                    screenId: screenId,
                    windowId: occupantId,
                    managed: nil,
                    reason: "activation-change-missing-occupant"
                )
                occupants.removeValue(forKey: screenId)
                continue
            }
            let occupantPid = window.backing.pid

            if host.shouldProtectTemporaryZoneOccupant(windowId: occupantId) {
                host.activateTemporaryZoneWindow(window, reason: "protection-reactivate")
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
    /// For focus-driven temporary-zone minimization, we only proceed if the window is
    /// still the temporary occupant at flush time.
    func prepareForDeferredMinimization(windowId: Int, reason: String) -> Bool {
        guard let host else { return false }

        guard isOcclusionBasedTemporaryMinimizationReason(reason) else {
            return true
        }

        guard let screenId = occupants.first(where: { $0.value == windowId })?.key else {
            Logger.debug(
                "Temporary zone deferred minimization skipped for window \(windowId): no longer temporary occupant (reason: \(reason))"
            )
            return false
        }

        guard isTemporaryZoneOccupantOccluded(on: screenId, occupantWindowId: windowId) else {
            Logger.debug(
                "Temporary zone deferred minimization skipped for window \(windowId): not occluded (reason: \(reason))"
            )
            return false
        }

        updateMostRecentOccupantSnapshot(
            screenId: screenId,
            windowId: windowId,
            managed: host.windowController.window(withId: windowId),
            reason: reason
        )

        host.clearTemporaryZoneProtection(windowId: windowId)
        occupants.removeValue(forKey: screenId)

        if let occupant = host.windowController.window(withId: windowId) {
            occupant.isInTemporaryZone = false
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
           let newZone = host.addZone(on: addZoneScreenId, announce: false, promoteTemporaryOccupant: false) {
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

        // Otherwise, leaving the temporary zone simply keeps the window floating.
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

        // Bookkeeping: move the dragged window to the destination screen's temporary zone.
        // Record as the origin screen's most recent occupant so indicator-click recall won't
        // accidentally revive an older minimized temp window on that screen.
        updateMostRecentOccupantSnapshot(
            screenId: originScreenId,
            windowId: managed.windowId,
            managed: nil,
            reason: "cross-screen-move"
        )
        occupants.removeValue(forKey: originScreenId)
        occupants[destinationScreenId] = managed.windowId
        host.setManagedWindow(managed, screenId: destinationScreenId, zoneIndex: nil)

        // If the destination already had a temporary occupant, swap it back to the origin screen.
        if let displacedWindow {
            occupants[originScreenId] = displacedWindow.windowId
            host.setManagedWindow(displacedWindow, screenId: originScreenId, zoneIndex: nil)

            if let descriptor = host.descriptor(for: originScreenId) {
                let placementFrame = placementFrame(for: displacedWindow, on: descriptor)
                host.windowController.showWindow(displacedWindow, at: placementFrame, on: descriptor)
            }

            Logger.debug(
                "Swapped temporary zone occupants: window \(managed.windowId) -> screen \(destinationIndex), " +
                    "window \(displacedWindow.windowId) -> screen \(originIndex)"
            )
        } else {
            Logger.debug("Moved temporary zone window \(managed.windowId) from screen \(originIndex) to screen \(destinationIndex)")
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

    /// Compute the placement frame for a window in the temporary zone without actually placing it.
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
        host: TemporaryZoneCoordinatorHost,
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
            "Temporary zone queued conditional minimization for occupant \(occupant.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))"
        )
    }

    private func isOcclusionBasedTemporaryMinimizationReason(_ reason: String) -> Bool {
        reason.hasPrefix("focus-shift-") ||
            reason == "workspace-activate" ||
            reason.hasPrefix("placeholder-") ||
            reason.hasPrefix("occlusion-check-")
    }

    private func updateMostRecentOccupantSnapshot(
        screenId: CGDirectDisplayID,
        windowId: Int,
        managed: ManagedWindow?,
        reason: String
    ) {
        guard let host else {
            return
        }

        let screenFrame: CGRect? = {
            guard let managed else { return nil }
            guard let descriptor = host.descriptor(for: screenId) else { return nil }
            return host.windowController.actualFrameInScreenCoordinates(for: managed, on: descriptor)
        }()

        mostRecentOccupantByScreenId[screenId] = RecallSnapshot(windowId: windowId, screenFrame: screenFrame)
        Logger.debug(
            "Temporary zone recorded most recent occupant for screen \(host.screenContextStore.loggingIndex(for: screenId)): " +
                "window \(windowId), frame \(screenFrame.map(String.init(describing:)) ?? "nil") (reason: \(reason))"
        )
    }

    private func isTemporaryZoneOccupantOccluded(on screenId: CGDirectDisplayID, occupantWindowId: Int) -> Bool {
        guard let host,
              let occupant = host.windowController.window(withId: occupantWindowId),
              let occupantFrame = host.windowController.actualFrameInAccessibilityCoordinates(for: occupant),
              let context = host.screenContexts[screenId] else {
            return false
        }

        var occluders: [OcclusionWindow] = []
        occluders.reserveCapacity(context.zoneController.allZones.count + 4)

        // Occupied tiling-zone managed windows.
        for zone in context.zoneController.allZones {
            guard let windowId = zone.occupantWindowId,
                  windowId != occupantWindowId,
                  let managed = host.windowController.window(withId: windowId),
                  let frame = host.windowController.actualFrameInAccessibilityCoordinates(for: managed) else {
                continue
            }
            occluders.append(OcclusionWindow(cgWindowId: managed.backing.cgWindowId, frame: frame))
        }

        // Empty-zone placeholders.
        occluders.append(contentsOf: host.placeholderOccluders(on: screenId))

        // Fast path: if nothing even overlaps geometrically, occlusion is impossible.
        guard occluders.contains(where: { !$0.frame.intersection(occupantFrame).isNull }) else {
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
