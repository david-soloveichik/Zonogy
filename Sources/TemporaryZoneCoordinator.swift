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
    func refreshIndicators()
    func updateTemporaryIndicatorHighlight(screenId: CGDirectDisplayID?)
    func activeScreenId() -> CGDirectDisplayID
    func detectScreenId(for window: ManagedWindow) -> CGDirectDisplayID?
    func resolveDisplacedWindow(_ displacedWindow: ManagedWindow?, preferredScreenId: CGDirectDisplayID?)
}

/// Centralizes temporary-zone occupant bookkeeping, placement, and targeting.
final class TemporaryZoneCoordinator {
    weak var host: TemporaryZoneCoordinatorHost?
    private(set) var occupants: [CGDirectDisplayID: Int] = [:]

    init(host: TemporaryZoneCoordinatorHost) {
        self.host = host
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
        guard let host else { return }
        let entries = occupants
        for (screenId, occupantId) in entries {
            guard let window = host.windowController.window(withId: occupantId),
                  case .accessibility(_, let occupantPid, _) = window.backing else {
                occupants.removeValue(forKey: screenId)
                continue
            }

            if occupantPid == pid {
                if focusedWindowId == occupantId {
                    continue
                }
                minimizeOccupant(on: screenId, reason: "focus-shift-same-app")
            } else {
                minimizeOccupant(on: screenId, reason: "focus-shift-other-app")
            }
        }
    }

    func handleActivationChange(focusedPid: pid_t?, reason: String) {
        guard let host else { return }
        let entries = occupants
        for (screenId, occupantId) in entries {
            guard let window = host.windowController.window(withId: occupantId),
                  case .accessibility(_, let occupantPid, _) = window.backing else {
                occupants.removeValue(forKey: screenId)
                continue
            }

            if let focusedPid, occupantPid == focusedPid {
                continue
            }

            minimizeOccupant(on: screenId, reason: reason)
        }
    }

    func refreshTargeting(reason: String) {
        guard let host else { return }
        if hasAvailableTiledZone(in: host.screenContexts) {
            if host.targetedZoneManager.targetedTemporaryScreenId != nil {
                let preferred = host.targetedZoneManager.targetedZoneKey?.screenId ?? host.activeScreenId()
                let fallback = host.targetedZoneManager.fallbackTargetedZone(preferredScreenId: preferred)
                host.targetedZoneManager.setTargetedZone(fallback, reason: reason)
            }
            return
        }

        let preferredScreen = host.targetedZoneManager.targetedZoneKey?.screenId
            ?? host.targetedZoneManager.targetedTemporaryScreenId
            ?? host.activeScreenId()
        host.targetedZoneManager.setTemporaryTarget(on: preferredScreen, reason: reason)
    }

    func finalizeFloatingDrop(
        windowId: Int,
        finalFrame: CGRect,
        hoveredAddZoneScreenId: CGDirectDisplayID?
    ) {
        guard let host,
              let managed = host.windowController.window(withId: windowId) else {
            return
        }

        if let hoveredAddZoneScreenId,
           let newZone = host.addZone(on: hoveredAddZoneScreenId, announce: false) {
            clear(windowId: windowId, minimize: false, reason: "floating-drop-add-zone")
            if let result = host.windowPlacementManager.assignWindowFromDrag(
                managed,
                to: ZoneKey(screenId: hoveredAddZoneScreenId, index: newZone.index)
            ) {
                host.resolveDisplacedWindow(result.displacedWindow, preferredScreenId: hoveredAddZoneScreenId)
            }
            return
        }

        // If the user dragged to the add-zone pillar, fall back to auto-add detection
        guard let dropScreenId = addZoneDropTarget(for: finalFrame) else {
            return
        }

        guard let newZone = host.addZone(on: dropScreenId, announce: false) else {
            Logger.debug("Unable to add zone on screen \(host.screenContextStore.loggingIndex(for: dropScreenId)) for floating drag drop")
            return
        }

        clear(windowId: windowId, minimize: false, reason: "floating-drop-add-zone")
        if let result = host.windowPlacementManager.assignWindowFromDrag(
            managed,
            to: ZoneKey(screenId: dropScreenId, index: newZone.index)
        ) {
            host.resolveDisplacedWindow(result.displacedWindow, preferredScreenId: dropScreenId)
        }
    }

    private func addZoneDropTarget(for accessibilityFrame: CGRect) -> CGDirectDisplayID? {
        guard let host else { return nil }
        let frame = accessibilityFrame.standardized
        for (screenId, context) in host.screenContexts {
            let descriptor = context.descriptor
            let zoneFrame = descriptor.screenToAccessibility(descriptor.visibleScreenBounds)
            if zoneFrame.intersects(frame) {
                return screenId
            }
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
        return hasAvailableTiledZone(in: host.screenContexts)
    }

    private func hasAvailableTiledZone(in contexts: [CGDirectDisplayID: ScreenContext]) -> Bool {
        for context in contexts.values {
            if context.zoneController.findEmptyZone() != nil {
                return true
            }
        }
        return false
    }
}
