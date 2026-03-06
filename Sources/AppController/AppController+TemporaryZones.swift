import Foundation
import AppKit

/// AppController extension for temporary zone assignment and management.
extension AppController {
    func temporaryZoneOccupant(on screenId: CGDirectDisplayID) -> ManagedWindow? {
        temporaryZoneCoordinator.occupant(on: screenId)
    }

    func isWindowInTemporaryZone(_ windowId: Int) -> Bool {
        temporaryZoneCoordinator.isWindowInTemporaryZone(windowId)
    }

    func cancelPendingMinimization(windowId: Int) {
        deferredMinimizationCoordinator.cancel(windowId: windowId)
    }

    func queueDeferredMinimization(windowId: Int, reason: String) {
        deferredMinimizationCoordinator.queue(windowId: windowId, reason: reason)
    }

    func prepareForDeferredMinimization(windowId: Int, reason: String) -> Bool {
        temporaryZoneCoordinator.prepareForDeferredMinimization(windowId: windowId, reason: reason)
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

        temporaryZoneCoordinator.assign(
            managed,
            to: screenId,
            centerWindow: centerWindow,
            reason: reason
        )
    }

    /// Checks all screens for temporary zone occupants that can be promoted into empty tiling zones.
    /// This is called automatically at the end of syncWindowsToZones when a tiling zone
    /// became newly empty since the previous sync pass.
    ///
    /// - Parameter newlyEmptiedZones: Zone keys that transitioned from occupied to empty since the prior sync.
    /// - Parameter excluding: Optional window ID to exclude from promotion (used when a window
    ///   was just placed INTO the temporary zone to prevent immediately moving it back out).
    /// - Parameter reason: Logging reason for the promotion.
    func promoteTemporaryZoneOccupantsIfNeeded(
        newlyEmptiedZones: Set<ZoneKey>,
        excluding windowId: Int? = nil,
        reason: String
    ) {
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

            // Only promote if the temp window overlaps the emptied zone's content frame
            // (frameWithMargin = zone frame with margin insets, ie the actual window area).
            guard let occupantFrame = windowController.actualFrameInAccessibilityCoordinates(for: occupant) else {
                continue
            }

            let descriptor = context.descriptor
            let candidateKeys: [ZoneKey] = newlyEmptiedZones
                .filter { $0.screenId == screenId }
                .filter { key in
                    guard let zone = context.zoneController.zone(at: key.index) else { return false }
                    let zoneFrame = descriptor.screenToAccessibility(frameWithMargin(for: zone, in: context.zoneController))
                    let intersection = occupantFrame.intersection(zoneFrame)
                    return !intersection.isNull && intersection.width > 1 && intersection.height > 1
                }
                .sorted(by: { $0.index < $1.index })

            guard !candidateKeys.isEmpty else {
                continue
            }

            let preferredKey: ZoneKey? = {
                guard let targeted = targetedZoneKey,
                      targeted.screenId == screenId,
                      candidateKeys.contains(targeted),
                      let zone = context.zoneController.zone(at: targeted.index),
                      isZoneEffectivelyEmpty(zone) else {
                    return nil
                }
                return targeted
            }()

            let fallbackKey: ZoneKey? = {
                for key in candidateKeys {
                    guard let zone = context.zoneController.zone(at: key.index),
                          isZoneEffectivelyEmpty(zone) else {
                        continue
                    }
                    return key
                }
                return nil
            }()

            guard let zoneKey = preferredKey ?? fallbackKey else {
                continue
            }

            Logger.debug("Promoting temp zone occupant \(occupant.windowId) to zone \(zoneKey.index) on screen \(screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
            windowPlacementManager.placeWindow(occupant, into: zoneKey, reason: reason)
        }
    }

    func clearTemporaryZone(for windowId: Int, minimize: Bool, reason: String) {
        temporaryZoneCoordinator.clear(windowId: windowId, minimize: minimize, reason: reason)
        clearTemporaryZoneProtection(windowId: windowId)
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

    /// Requests occlusion-based minimization of the temporary-zone occupant on `screenId`
    /// after a window was placed into a tiling zone on that screen.
    /// This does not guarantee the temporary zone is emptied.
    func queueOcclusionBasedTemporaryZoneMinimizationIfNeeded(on screenId: CGDirectDisplayID, excluding windowId: Int? = nil, reason: String) {
        guard let occupant = temporaryZoneOccupant(on: screenId) else {
            return
        }
        if let windowId, occupant.windowId == windowId {
            return
        }
        if shouldProtectTemporaryZoneOccupant(windowId: occupant.windowId) {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug("Skipping temporary zone minimization for protected temporary-zone window \(occupant.windowId) on screen \(screenIndex) (reason: \(reason))")
            extendTemporaryZoneProtection(windowId: occupant.windowId)
            return
        }
        queueDeferredMinimization(windowId: occupant.windowId, reason: "occlusion-check-\(reason)")
    }

    func activateTemporaryZoneWindow(_ managed: ManagedWindow, reason: String) {
        let logPrefix = "Temporary zone activation"
        let pid = managed.backing.pid
        let element = managed.backing.element
        let windowId = managed.windowId

        // Workaround: without this, the window may appear behind tiled windows.
        // See SPECIFICATION-IMPLEMENTATION.md "Temporary zone activation workaround".
        NSApp.activate(ignoringOtherApps: true)
        scheduleWindowRaise(
            pid: pid,
            element: element,
            logPrefix: logPrefix,
            reason: reason,
            afterRaise: { [weak self] in
                // Extend protection after the async activation to cover any subsequent focus events.
                self?.extendTemporaryZoneProtection(windowId: windowId)
            }
        )
    }

}
