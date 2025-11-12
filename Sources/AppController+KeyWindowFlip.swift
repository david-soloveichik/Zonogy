import Foundation
import AppKit

/// Implements Control-Cmd-Enter key window flip behavior across screens.
extension AppController {
    /// Entry point for the flip shortcut; rehomes the key window to a zone on another screen.
    func flipKeyWindowToAnotherScreen() {
        guard screenContexts.count > 1 else {
            Logger.debug("Flip key window ignored: only one screen available")
            return
        }

        guard let managed = frontmostManagedKeyWindow() else {
            Logger.debug("Flip key window aborted: no managed key window available")
            return
        }

        guard let originKey = zoneKey(forManagedWindow: managed) else {
            Logger.debug("Flip key window aborted: window \(managed.windowId) is not assigned to a zone")
            return
        }

        targetedZoneManager.ensureTargetedZone(reason: "flip-key-window")
        guard let currentTarget = targetedZoneManager.targetedZoneKey else {
            Logger.debug("Flip key window aborted: targeted zone unavailable")
            return
        }

        guard let destinationKey = resolveFlipDestination(originKey: originKey, targetedKey: currentTarget) else {
            Logger.debug("Flip key window aborted: unable to resolve destination zone")
            return
        }

        if destinationKey != currentTarget {
            targetedZoneManager.setTargetedZone(destinationKey, reason: "flip-key-window-select-destination")
        }

        guard windowPlacementManager.moveWindow(managed, from: originKey, to: destinationKey) else {
            let failureReason = "flip-key-window-failure"
            if targetedZoneManager.zoneExists(originKey) {
                targetedZoneManager.setTargetedZone(originKey, reason: failureReason)
            } else {
                targetedZoneManager.ensureTargetedZone(reason: failureReason)
            }
            return
        }

        if targetedZoneManager.zoneExists(originKey) {
            targetedZoneManager.setTargetedZone(originKey, reason: "flip-key-window-origin-retarget")
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "flip-key-window-origin-missing")
        }
        syncWindowsToZones()
    }

    /// Returns the focused managed window for the current frontmost app, if it is eligible to flip.
    private func frontmostManagedKeyWindow() -> ManagedWindow? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            Logger.debug("Flip key window aborted: unable to determine frontmost application")
            return nil
        }

        let pid = application.processIdentifier
        guard pid != getpid() else {
            Logger.debug("Flip key window aborted: LatticeTopology is the frontmost application")
            return nil
        }

        guard let managed = windowController.focusedWindowIfTracked(pid: pid) else {
            Logger.debug("Flip key window aborted: pid \(pid) has no tracked focused window")
            return nil
        }

        if managed.isPlaceholder {
            Logger.debug("Flip key window aborted: focused managed window \(managed.windowId) is a placeholder")
            return nil
        }

        return managed
    }

    /// Resolves the current zone assignment for a managed window, consulting cached metadata if needed.
    private func zoneKey(forManagedWindow managed: ManagedWindow) -> ZoneKey? {
        if let screenId = managed.screenDisplayId,
           let index = managed.zoneIndex {
            return ZoneKey(screenId: screenId, index: index)
        }

        for (screenId, context) in screenContexts {
            if let zone = context.zoneController.zoneForWindow(windowId: managed.windowId) {
                return ZoneKey(screenId: screenId, index: zone.index)
            }
        }

        return nil
    }

    /// Selects the destination zone per specification rules (targeted zone if off-screen, otherwise new screen selection).
    private func resolveFlipDestination(originKey: ZoneKey, targetedKey: ZoneKey) -> ZoneKey? {
        if targetedKey.screenId != originKey.screenId {
            guard let context = screenContexts[targetedKey.screenId],
                  context.zoneController.zone(at: targetedKey.index) != nil else {
                Logger.debug("Flip key window aborted: targeted zone \(targetedKey.index) unavailable on screen \(targetedKey.screenId)")
                return nil
            }
            return targetedKey
        }

        guard let destinationScreenId = firstAlternateScreenId(excluding: originKey.screenId) else {
            Logger.debug("Flip key window aborted: no alternate screen available")
            return nil
        }

        guard let destinationZoneIndex = selectZoneIndex(on: destinationScreenId) else {
            Logger.debug("Flip key window aborted: destination screen \(destinationScreenId) has no zones")
            return nil
        }

        return ZoneKey(screenId: destinationScreenId, index: destinationZoneIndex)
    }

    /// Returns the first available display that is different from the given origin screen.
    private func firstAlternateScreenId(excluding screenId: CGDirectDisplayID) -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let candidateId = ScreenContextStore.displayId(for: screen),
                  candidateId != screenId,
                  screenContexts[candidateId] != nil else {
                continue
            }
            return candidateId
        }
        return nil
    }

    /// Picks the lowest empty zone on the screen, or the highest occupied one when no zones are empty.
    private func selectZoneIndex(on screenId: CGDirectDisplayID) -> Int? {
        guard let context = screenContexts[screenId] else {
            return nil
        }

        let zones = context.zoneController.allZones
        if let emptyIndex = zones.filter({ $0.isEmpty }).min(by: { $0.index < $1.index })?.index {
            return emptyIndex
        }

        return zones.filter { !$0.isEmpty }.max(by: { $0.index < $1.index })?.index
    }

}
