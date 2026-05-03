import Foundation
import AppKit

/// AppController extension for floating zone assignment and management.
extension AppController {
    func floatingZoneOccupant(on screenId: CGDirectDisplayID) -> ManagedWindow? {
        floatingZoneCoordinator.occupant(on: screenId)
    }

    func isWindowInFloatingZone(_ windowId: Int) -> Bool {
        floatingZoneCoordinator.isWindowInFloatingZone(windowId)
    }

    func cancelPendingMinimization(windowId: Int) {
        deferredMinimizationCoordinator.cancel(windowId: windowId)
    }

    func queueDeferredMinimization(windowId: Int, reason: String) {
        deferredMinimizationCoordinator.queue(windowId: windowId, reason: reason)
    }

    func prepareForDeferredMinimization(windowId: Int, reason: String) -> Bool {
        floatingZoneCoordinator.prepareForDeferredMinimization(windowId: windowId, reason: reason)
    }

    func assignWindowToFloatingZone(
        _ managed: ManagedWindow,
        on screenId: CGDirectDisplayID,
        centerWindow: Bool = true,
        reason: String,
        displacement: DisplacementStrategy = .synchronous
    ) {
        // Invariant: when a floating-zone window is active, no tiled window
        // should remain in ActiveFit reveal mode. Exit reveal mode for any
        // existing ActiveFit window before assigning to the floating zone.
        exitRevealMode(reason: "floating-zone-assignment")

        floatingZoneCoordinator.assign(
            managed,
            to: screenId,
            centerWindow: centerWindow,
            reason: reason,
            displacement: displacement
        )
    }

    /// Checks all screens for floating zone occupants that can be promoted into empty tiling zones.
    /// This is called automatically at the end of syncWindowsToZones when a tiling zone
    /// became newly empty since the previous sync pass.
    ///
    /// - Parameter newlyEmptiedZones: Zone keys that transitioned from occupied to empty since the prior sync.
    /// - Parameter excluding: Optional window ID to exclude from promotion (used when a window
    ///   was just placed INTO the floating zone to prevent immediately moving it back out).
    /// - Parameter reason: Logging reason for the promotion.
    func promoteFloatingZoneOccupantsIfNeeded(
        newlyEmptiedZones: Set<ZoneKey>,
        excluding windowId: Int? = nil,
        reason: String
    ) {
        for screenId in screenOrder {
            guard let occupant = floatingZoneOccupant(on: screenId) else {
                continue
            }

            // Don't promote the excluded window (e.g., window just placed into floating zone)
            if let excludeId = windowId, occupant.windowId == excludeId {
                continue
            }

            guard let context = screenContexts[screenId] else {
                continue
            }

            // Only promote if the floating window overlaps the emptied zone's frame.
            guard let occupantFrame = windowController.actualFrameInAccessibilityCoordinates(for: occupant) else {
                continue
            }

            let descriptor = context.descriptor
            let candidateKeys: [ZoneKey] = newlyEmptiedZones
                .filter { $0.screenId == screenId }
                .filter { key in
                    guard let zone = context.zoneController.zone(at: key.index) else { return false }
                    let zoneFrame = descriptor.screenToAccessibility(zone.frame)
                    return FloatingZoneOverlapPolicy.overlapsZoneFrame(
                        floatingFrame: occupantFrame,
                        zoneFrame: zoneFrame
                    )
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

            Logger.debug("Promoting floating zone occupant \(occupant.windowId) to zone \(zoneKey.index) on screen \(screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
            windowPlacementManager.placeWindow(occupant, into: zoneKey, reason: reason)
        }
    }

    func clearFloatingZone(for windowId: Int, minimize: Bool, reason: String) {
        floatingZoneCoordinator.clear(windowId: windowId, minimize: minimize, reason: reason)
        clearFloatingZoneProtection(windowId: windowId)
    }

    func handleFloatingZoneFocusChange(pid: pid_t, focusedWindowId: Int?) {
        floatingZoneCoordinator.handleFocusChange(pid: pid, focusedWindowId: focusedWindowId)
    }

    func handleFloatingZoneActivationChange(focusedPid: pid_t?, reason: String) {
        floatingZoneCoordinator.handleActivationChange(focusedPid: focusedPid, reason: reason)
    }

    func hasAvailableTiledZone() -> Bool {
        floatingZoneCoordinator.hasAvailableTiledZone()
    }

    func screenIdForAccessibilityFrame(_ frame: CGRect) -> CGDirectDisplayID? {
        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: frame,
            primaryScreenBounds: primaryScreenBounds
        )
        return screenIdForCocoaFrame(cocoaFrame)
    }

    func finalizeFloatingDrop(
        windowId: Int,
        finalFrame: CGRect,
        hoveredAddZoneScreenId: CGDirectDisplayID?,
        hoveredFloatingScreenId: CGDirectDisplayID?,
        finalCursorPoint: CGPoint?
    ) {
        floatingZoneCoordinator.finalizeFloatingDrop(
            windowId: windowId,
            finalFrame,
            hoveredAddZoneScreenId: hoveredAddZoneScreenId,
            hoveredFloatingScreenId: hoveredFloatingScreenId,
            finalCursorPoint: finalCursorPoint
        )
        tiledToFloatingDragContexts.removeValue(forKey: windowId)
    }

    /// Requests occlusion-based minimization of the floating-zone occupant on `screenId`
    /// after a window was placed into a tiling zone on that screen.
    /// This does not guarantee the floating zone is emptied.
    func queueOcclusionBasedFloatingZoneMinimizationIfNeeded(on screenId: CGDirectDisplayID, excluding windowId: Int? = nil, reason: String) {
        guard let occupant = floatingZoneOccupant(on: screenId) else {
            return
        }
        if let windowId, occupant.windowId == windowId {
            return
        }
        if shouldProtectFloatingZoneOccupant(windowId: occupant.windowId) {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug("Skipping floating zone minimization for protected floating-zone window \(occupant.windowId) on screen \(screenIndex) (reason: \(reason))")
            extendFloatingZoneProtection(windowId: occupant.windowId)
            return
        }
        queueDeferredMinimization(windowId: occupant.windowId, reason: "occlusion-check-\(reason)")
    }

    func activateFloatingZoneWindow(_ managed: ManagedWindow, reason: String) {
        let logPrefix = "Floating zone activation"
        let pid = managed.backing.pid
        let element = managed.backing.element
        let windowId = managed.windowId

        // Workaround: without this, the window may appear behind tiled windows.
        // See SPECIFICATION-IMPLEMENTATION.md "Floating zone activation workaround".
        NSApp.activate(ignoringOtherApps: true)
        scheduleWindowRaise(
            pid: pid,
            element: element,
            logPrefix: logPrefix,
            reason: reason,
            afterRaise: { [weak self] in
                // Extend protection after the async activation to cover any subsequent focus events.
                self?.extendFloatingZoneProtection(windowId: windowId)
            }
        )
    }

}
