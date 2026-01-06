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
        // Invariant: when a temporary-zone window is active, no tiled window
        // should remain in ActiveFit reveal mode. Exit reveal mode for any
        // existing ActiveFit window before assigning to the temporary zone.
        exitRevealMode(reason: "temporary-zone-assignment")

        temporaryZoneCoordinator.assign(managed, to: screenId, centerWindow: centerWindow, reason: reason)
        updateTemporaryZoneTargeting(reason: reason)
    }

    /// Checks all screens for temporary zone occupants that can be promoted into empty tiling zones.
    /// This is called automatically at the end of syncWindowsToZones.
    ///
    /// - Parameter excluding: Optional window ID to exclude from promotion (used when a window
    ///   was just placed INTO the temporary zone to prevent immediately moving it back out).
    /// - Parameter reason: Logging reason for the promotion.
    func promoteTemporaryZoneOccupantsIfNeeded(excluding windowId: Int? = nil, reason: String) {
        func isEffectivelyEmpty(_ zone: Zone) -> Bool {
            guard let existingId = zone.windowId else {
                return true
            }
            guard let existing = windowController.window(withId: existingId) else {
                return false
            }
            return existing.isPlaceholder
        }

        for screenId in screenOrder {
            guard let occupant = temporaryZoneOccupant(on: screenId) else {
                continue
            }

            // Don't promote the excluded window (e.g., window just placed into temp zone)
            if let excludeId = windowId, occupant.windowId == excludeId {
                continue
            }

            guard let context = screenContexts[screenId] else {
                continue
            }

            let preferredEmptyKey: ZoneKey? = {
                guard let key = targetedZoneKey,
                      key.screenId == screenId,
                      let zone = context.zoneController.zone(at: key.index),
                      isEffectivelyEmpty(zone) else {
                    return nil
                }
                return key
            }()

            let fallbackEmptyKey: ZoneKey? = {
                for zone in context.zoneController.allZones.sorted(by: { $0.index < $1.index }) {
                    if isEffectivelyEmpty(zone) {
                        return ZoneKey(screenId: screenId, index: zone.index)
                    }
                }
                return nil
            }()

            guard let zoneKey = preferredEmptyKey ?? fallbackEmptyKey else {
                continue
            }

            Logger.debug("Promoting temp zone occupant \(occupant.windowId) to zone \(zoneKey.index) on screen \(screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
            windowPlacementManager.placeWindow(occupant, into: zoneKey, reason: reason)
        }
    }

    func minimizeTemporaryZoneOccupant(on screenId: CGDirectDisplayID, reason: String) {
        if let occupant = temporaryZoneOccupant(on: screenId) {
            clearTemporaryZoneProtection(windowId: occupant.windowId)
        }
        temporaryZoneCoordinator.minimizeOccupant(on: screenId, reason: reason)
    }

    func clearTemporaryZone(for windowId: Int, minimize: Bool, reason: String) {
        temporaryZoneCoordinator.clear(windowId: windowId, minimize: minimize, reason: reason)
        clearTemporaryZoneProtection(windowId: windowId)
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

    func screenIdForAccessibilityFrame(_ frame: CGRect) -> CGDirectDisplayID? {
        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: frame,
            primaryScreenBounds: primaryScreenBounds
        )
        return screenIdForCocoaFrame(cocoaFrame)
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
            extendTemporaryZoneProtection(windowId: occupant.windowId)
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
