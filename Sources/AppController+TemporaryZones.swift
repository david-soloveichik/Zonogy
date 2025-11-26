import Foundation
import AppKit

extension AppController {
    func temporaryZoneOccupant(on screenId: CGDirectDisplayID) -> ManagedWindow? {
        temporaryZoneCoordinator.occupant(on: screenId)
    }

    func isWindowInTemporaryZone(_ windowId: Int) -> Bool {
        temporaryZoneCoordinator.isWindowInTemporaryZone(windowId)
    }

    func assignWindowToTemporaryZone(
        _ managed: ManagedWindow,
        on screenId: CGDirectDisplayID,
        centerWindow: Bool = true,
        reason: String
    ) {
        temporaryZoneCoordinator.assign(managed, to: screenId, centerWindow: centerWindow, reason: reason)
        clearTemporaryZoneWakeProtection(windowId: managed.windowId)
        updateTemporaryZoneTargeting(reason: reason)
    }

    func minimizeTemporaryZoneOccupant(on screenId: CGDirectDisplayID, reason: String) {
        if let occupant = temporaryZoneOccupant(on: screenId) {
            clearTemporaryZoneWakeProtection(windowId: occupant.windowId)
        }
        temporaryZoneCoordinator.minimizeOccupant(on: screenId, reason: reason)
    }

    func clearTemporaryZone(for windowId: Int, minimize: Bool, reason: String) {
        temporaryZoneCoordinator.clear(windowId: windowId, minimize: minimize, reason: reason)
        clearTemporaryZoneWakeProtection(windowId: windowId)
    }

    func updateTemporaryZoneTargeting(reason: String) {
        temporaryZoneCoordinator.refreshTargeting(reason: reason)
    }

    func handleTemporaryZoneFocusChange(pid: pid_t, focusedWindowId: Int?) {
        temporaryZoneCoordinator.handleFocusChange(pid: pid, focusedWindowId: focusedWindowId)
    }

    func handleTemporaryZoneActivationChange(focusedPid: pid_t?, reason: String) {
        temporaryZoneCoordinator.handleActivationChange(focusedPid: focusedPid, reason: reason)
    }

    func hasAvailableTiledZone() -> Bool {
        temporaryZoneCoordinator.hasAvailableTiledZone()
    }

    func finalizeFloatingTemporaryDrop(
        windowId: Int,
        finalFrame: CGRect,
        hoveredAddZoneScreenId: CGDirectDisplayID?,
        finalCursorPoint: CGPoint?
    ) {
        temporaryZoneCoordinator.finalizeFloatingDrop(
            windowId: windowId,
            finalFrame,
            hoveredAddZoneScreenId: hoveredAddZoneScreenId,
            finalCursorPoint: finalCursorPoint
        )
        tiledToTemporaryDragContexts.removeValue(forKey: windowId)
    }

    func emptyTemporaryZoneForNewTiledPlacement(on screenId: CGDirectDisplayID, excluding windowId: Int, reason: String) {
        guard let occupant = temporaryZoneOccupant(on: screenId) else {
            return
        }
        guard occupant.windowId != windowId else {
            return
        }
        if shouldProtectTemporaryZoneOccupant(windowId: occupant.windowId) {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug("Skipping temporary zone minimization for protected temporary-zone window \(occupant.windowId) on screen \(screenIndex) (reason: \(reason))")
            scheduleTemporaryZoneWakeProtection(windowId: occupant.windowId)
            return
        }
        minimizeTemporaryZoneOccupant(on: screenId, reason: reason)
    }

    func activateTemporaryZoneWindow(_ managed: ManagedWindow, reason: String) {
        guard !managed.isPlaceholder else {
            return
        }

        let logPrefix = "Temporary zone activation"

        switch managed.backing {
        case .appKit(let window):
            let activate = {
                window.makeKeyAndOrderFront(nil)
                Logger.debug("\(logPrefix): ordered front AppKit window \(managed.windowId) (reason: \(reason))")
            }
            if Thread.isMainThread {
                activate()
            } else {
                DispatchQueue.main.async(execute: activate)
            }
        case .accessibility(_, let pid, _):
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                Logger.debug("\(logPrefix): unable to resolve application for pid \(pid) (reason: \(reason))")
                return
            }
            let activate = {
                let result = app.activate(options: [.activateIgnoringOtherApps])
                Logger.debug("\(logPrefix): activated pid \(pid) (result: \(result)) (reason: \(reason))")
            }
            if Thread.isMainThread {
                activate()
            } else {
                DispatchQueue.main.async(execute: activate)
            }
        }
    }
}
