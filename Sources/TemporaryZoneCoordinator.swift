import AppKit

/// Defines the operations the temporary-zone coordinator can call back into.
protocol TemporaryZoneCoordinatorHost: AnyObject {
    var windowController: WindowController { get }
    var targetedZoneManager: TargetedZoneManager { get }
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    var screenContextStore: ScreenContextStore { get }
    var windowPlacementManager: WindowPlacementManager { get }

    func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?
    func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?)
    func clearManagedWindowZone(_ managed: ManagedWindow)
    func addZone(on screenId: CGDirectDisplayID, announce: Bool) -> Zone?
    func addZoneIndicatorHitAreas() -> [CGDirectDisplayID: CGRect]
    func refreshIndicators()
    func updateTemporaryIndicatorHighlight(screenId: CGDirectDisplayID?)
    func activeScreenId() -> CGDirectDisplayID
    func detectScreenId(for window: ManagedWindow) -> CGDirectDisplayID?
    func shouldProtectTemporaryZoneOccupant(windowId: Int) -> Bool
    func activateTemporaryZoneWindow(_ managed: ManagedWindow, reason: String)
}

/// Centralizes temporary-zone occupant bookkeeping, placement, and targeting.
final class TemporaryZoneCoordinator {
    weak var host: TemporaryZoneCoordinatorHost?
    private let displacedWindowCoordinator: DisplacedWindowCoordinator
    private(set) var occupants: [CGDirectDisplayID: Int] = [:]
    private var lastEmptyZoneCount: Int?

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

        if isWindowInTemporaryZone(managed.windowId) {
            clear(windowId: managed.windowId, minimize: false, reason: "temporary-zone-reassign")
        }

        if let occupantId = occupants[screenId], occupantId != managed.windowId {
            minimizeOccupant(on: screenId, reason: "replace-with-new-window")
        }

        occupants[screenId] = managed.windowId
        host.setManagedWindow(managed, screenId: screenId, zoneIndex: nil)

        if centerWindow,
           let descriptor = host.descriptor(for: screenId) {
            let frame = placementFrame(for: managed, on: descriptor)
            host.windowController.showWindow(managed, at: frame, on: descriptor)
        }

        host.activateTemporaryZoneWindow(managed, reason: reason)

        Logger.debug("Assigned window \(managed.windowId) to temporary zone on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
        host.refreshIndicators()
    }

    func minimizeOccupant(on screenId: CGDirectDisplayID, reason: String) {
        guard let host,
              let occupant = occupant(on: screenId) else {
            return
        }
        occupants.removeValue(forKey: screenId)
        host.clearManagedWindowZone(occupant)
        host.windowController.minimizeWindow(occupant)
        Logger.debug("Temporary zone minimized occupant \(occupant.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
        refreshTargeting(reason: reason)
        host.refreshIndicators()
    }

    func clear(windowId: Int, minimize: Bool, reason: String) {
        guard let host,
              let entry = occupants.first(where: { $0.value == windowId }) else {
            return
        }
        occupants.removeValue(forKey: entry.key)
        Logger.debug("Cleared temporary zone occupant \(windowId) on screen \(host.screenContextStore.loggingIndex(for: entry.key)) (reason: \(reason))")
        if minimize, let window = host.windowController.window(withId: windowId) {
            host.clearManagedWindowZone(window)
            host.windowController.minimizeWindow(window)
        }
        refreshTargeting(reason: reason)
        host.refreshIndicators()
    }

    func handleFocusChange(pid: pid_t, focusedWindowId: Int?) {
        guard let host,
              let focusContext = tiledFocusContext(pid: pid, focusedWindowId: focusedWindowId) else {
            return
        }

        let entries = occupants
        for (screenId, occupantId) in entries {
            guard let window = host.windowController.window(withId: occupantId),
                  case .accessibility(_, let occupantPid, _) = window.backing else {
                occupants.removeValue(forKey: screenId)
                continue
            }

            if host.shouldProtectTemporaryZoneOccupant(windowId: occupantId) {
                continue
            }

            if occupantPid == focusContext.pid {
                if focusContext.window.windowId == occupantId {
                    continue
                }
                minimizeOccupant(on: screenId, reason: "focus-shift-same-app")
            } else {
                minimizeOccupant(on: screenId, reason: "focus-shift-other-app")
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
        for (screenId, occupantId) in entries {
            guard let window = host.windowController.window(withId: occupantId),
                  case .accessibility(_, let occupantPid, _) = window.backing else {
                occupants.removeValue(forKey: screenId)
                continue
            }

            if host.shouldProtectTemporaryZoneOccupant(windowId: occupantId) {
                continue
            }

            if occupantPid == focusContext.pid,
               focusContext.window.windowId == occupantId {
                continue
            }

            minimizeOccupant(on: screenId, reason: reason)
        }
    }

    func refreshTargeting(reason: String) {
        guard let host else { return }

        let emptyCount = emptyZoneCount(in: host.screenContexts)
        let previousCount = lastEmptyZoneCount ?? emptyCount
        defer { lastEmptyZoneCount = emptyCount }

        if emptyCount > 0 {
            if host.targetedZoneManager.targetedTemporaryScreenId != nil {
                let preferred = host.targetedZoneManager.targetedZoneKey?.screenId ?? host.activeScreenId()
                let fallback = host.targetedZoneManager.fallbackTargetedZone(preferredScreenId: preferred)
                host.targetedZoneManager.setTargetedZone(fallback, reason: reason)
            }
            return
        }

        if previousCount > 0 {
            let preferredScreen = host.targetedZoneManager.targetedZoneKey?.screenId
                ?? host.targetedZoneManager.targetedTemporaryScreenId
                ?? host.activeScreenId()
            host.targetedZoneManager.setTemporaryTarget(on: preferredScreen, reason: reason)
        }
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
           let newZone = host.addZone(on: addZoneScreenId, announce: false) {
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

        // Otherwise, leaving the temporary zone simply keeps the window floating.
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
            width = bounds.width * 0.55
            height = bounds.height * 0.55
        }

        width = min(max(width, minWidth), maxWidth)
        height = min(max(height, minHeight), maxHeight)

        var originX = bounds.midX - width / 2
        var originY = bounds.midY - height / 2
        originX = max(bounds.minX, min(originX, bounds.maxX - width))
        originY = max(bounds.minY, min(originY, bounds.maxY - height))
        return CGRect(x: originX, y: originY, width: width, height: height)
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

    private func tiledFocusContext(pid: pid_t, focusedWindowId: Int?) -> (window: ManagedWindow, pid: pid_t)? {
        guard let host,
              let managed = resolvedFocusedWindow(host: host, pid: pid, focusedWindowId: focusedWindowId),
              isTiledWindow(managed) else {
            return nil
        }

        let resolvedPid = accessibilityPid(for: managed) ?? pid
        return (managed, resolvedPid)
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
        guard !window.isPlaceholder else {
            return false
        }
        return window.zoneIndex != nil
    }

    private func accessibilityPid(for window: ManagedWindow) -> pid_t? {
        if case .accessibility(_, let pid, _) = window.backing {
            return pid
        }
        return nil
    }
}
