import Foundation
import AppKit

/// Temporary zone state management and targeting helpers.
extension AppController {
    func temporaryZoneOccupant(on screenId: CGDirectDisplayID) -> ManagedWindow? {
        guard let windowId = temporaryZoneOccupants[screenId] else {
            return nil
        }
        return windowController.window(withId: windowId)
    }

    func isWindowInTemporaryZone(_ windowId: Int) -> Bool {
        return temporaryZoneOccupants.values.contains(windowId)
    }

    func assignWindowToTemporaryZone(
        _ managed: ManagedWindow,
        on screenId: CGDirectDisplayID,
        centerWindow: Bool = true,
        reason: String
    ) {
        if isWindowInTemporaryZone(managed.windowId) {
            clearTemporaryZone(for: managed.windowId, minimize: false, reason: "temporary-zone-reassign")
        }
        if let occupantId = temporaryZoneOccupants[screenId], occupantId != managed.windowId {
            minimizeTemporaryZoneOccupant(on: screenId, reason: "replace-with-new-window")
        }

        temporaryZoneOccupants[screenId] = managed.windowId
        setManagedWindow(managed, screenId: screenId, zoneIndex: nil)

        if centerWindow, let descriptor = descriptor(for: screenId) {
            let frame = temporaryPlacementFrame(for: managed, on: descriptor)
            windowController.showWindow(managed, at: frame, on: descriptor)
        }

        Logger.debug("Assigned window \(managed.windowId) to temporary zone on screen \(screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
        updateTemporaryZoneTargeting(reason: reason)
        refreshIndicators()
    }

    func minimizeTemporaryZoneOccupant(on screenId: CGDirectDisplayID, reason: String) {
        guard let occupant = temporaryZoneOccupant(on: screenId) else {
            return
        }
        temporaryZoneOccupants.removeValue(forKey: screenId)
        clearManagedWindowZone(occupant)
        windowController.minimizeWindow(occupant)
        Logger.debug("Temporary zone minimized occupant \(occupant.windowId) on screen \(screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
        updateTemporaryZoneTargeting(reason: reason)
        refreshIndicators()
    }

    func clearTemporaryZone(for windowId: Int, minimize: Bool, reason: String) {
        guard let entry = temporaryZoneOccupants.first(where: { $0.value == windowId }) else {
            return
        }
        temporaryZoneOccupants.removeValue(forKey: entry.key)
        Logger.debug("Cleared temporary zone occupant \(windowId) on screen \(screenContextStore.loggingIndex(for: entry.key)) (reason: \(reason))")
        if minimize, let window = windowController.window(withId: windowId) {
            clearManagedWindowZone(window)
            windowController.minimizeWindow(window)
        }
        updateTemporaryZoneTargeting(reason: reason)
        refreshIndicators()
    }

    func updateTemporaryZoneTargeting(reason: String) {
        if hasAvailableTiledZone() {
            if targetedZoneManager.targetedTemporaryScreenId != nil {
                let preferred = targetedZoneManager.targetedZoneKey?.screenId ?? activeScreenId()
                let fallback = targetedZoneManager.fallbackTargetedZone(preferredScreenId: preferred)
                targetedZoneManager.setTargetedZone(fallback, reason: reason)
            }
            return
        }

        let preferredScreen = targetedZoneManager.targetedZoneKey?.screenId
            ?? targetedZoneManager.targetedTemporaryScreenId
            ?? activeScreenId()
        targetedZoneManager.setTemporaryTarget(on: preferredScreen, reason: reason)
    }

    func handleTemporaryZoneFocusChange(pid: pid_t, focusedWindowId: Int?) {
        let occupants = Array(temporaryZoneOccupants)
        for (screenId, occupantId) in occupants {
            guard let window = windowController.window(withId: occupantId) else {
                temporaryZoneOccupants.removeValue(forKey: screenId)
                continue
            }

            var occupantPid: pid_t?
            if case .accessibility(_, let pid, _) = window.backing {
                occupantPid = pid
            }

            guard let resolvedPid = occupantPid else {
                continue
            }

            if resolvedPid == pid {
                if focusedWindowId == occupantId {
                    continue
                }
                minimizeTemporaryZoneOccupant(on: screenId, reason: "focus-shift-same-app")
            } else {
                minimizeTemporaryZoneOccupant(on: screenId, reason: "focus-shift-other-app")
            }
        }
    }

    func handleTemporaryZoneActivationChange(focusedPid: pid_t?, reason: String) {
        let occupants = Array(temporaryZoneOccupants)
        for (screenId, occupantId) in occupants {
            guard let window = windowController.window(withId: occupantId) else {
                temporaryZoneOccupants.removeValue(forKey: screenId)
                continue
            }

            guard case .accessibility(_, let occupantPid, _) = window.backing else {
                continue
            }

            if let focusedPid, occupantPid == focusedPid {
                continue
            }

            minimizeTemporaryZoneOccupant(on: screenId, reason: reason)
        }
    }

    func hasAvailableTiledZone() -> Bool {
        for context in screenContexts.values {
            if context.zoneController.findEmptyZone() != nil {
                return true
            }
        }
        return false
    }

    private func temporaryPlacementFrame(for managed: ManagedWindow, on descriptor: ScreenDescriptor) -> CGRect {
        let bounds = descriptor.visibleScreenBounds.standardized
        let minWidth = bounds.width * 0.35
        let maxWidth = bounds.width * 0.8
        let minHeight = bounds.height * 0.35
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

    func handleFloatingTemporaryDragEnd(windowId: Int, finalFrame: CGRect) {
        guard let entry = temporaryZoneOccupants.first(where: { $0.value == windowId }) else {
            syncWindowsToZones()
            return
        }

        guard let managed = windowController.window(withId: windowId) else {
            temporaryZoneOccupants.removeValue(forKey: entry.key)
            syncWindowsToZones()
            return
        }

        defer {
            syncWindowsToZones()
        }

        if let newScreenId = detectScreenId(for: managed), newScreenId != entry.key {
            temporaryZoneOccupants.removeValue(forKey: entry.key)
            temporaryZoneOccupants[newScreenId] = windowId
            setManagedWindow(managed, screenId: newScreenId, zoneIndex: nil)
            Logger.debug("Temporary zone window \(windowId) moved to screen \(screenContextStore.loggingIndex(for: newScreenId)) via drag")
        }

        guard let dropScreenId = temporaryAddZoneDropTarget(for: finalFrame) else {
            return
        }

        guard let newZone = addZone(on: dropScreenId, announce: false) else {
            Logger.debug("Unable to add zone on screen \(screenContextStore.loggingIndex(for: dropScreenId)) for floating drag drop")
            return
        }

        clearTemporaryZone(for: windowId, minimize: false, reason: "floating-drop-add-zone")
        if let result = windowPlacementManager.assignWindowFromDrag(
            managed,
            to: ZoneKey(screenId: dropScreenId, index: newZone.index)
        ) {
            resolveDisplacedWindow(result.displacedWindow, preferredScreenId: dropScreenId)
        }
    }

    private func temporaryAddZoneDropTarget(for accessibilityFrame: CGRect) -> CGDirectDisplayID? {
        let frame = accessibilityFrame.standardized
        for (screenId, hitArea) in currentAddZoneIndicatorHitAreas {
            if frame.intersects(hitArea) {
                return screenId
            }
        }
        return nil
    }
}
