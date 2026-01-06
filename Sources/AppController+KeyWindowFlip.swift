import Foundation
import AppKit

/// Implements Control-Cmd-\ key window flip behavior across screens.
extension AppController {
    /// Entry point for the flip shortcut; rehomes the key window to a zone on another screen.
    func flipKeyWindowToAnotherScreen() {
        guard screenContexts.count > 1 else {
            Logger.debug("Flip key window ignored: only one screen available")
            return
        }

        guard let (managed, _) = managedWindowForFrontmostApplication(logPrefix: "Flip key window aborted") else {
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

    /// Selects the destination zone per specification rules (targeted zone if off-screen, otherwise new screen selection).
    private func resolveFlipDestination(originKey: ZoneKey, targetedKey: ZoneKey) -> ZoneKey? {
        if targetedKey.screenId != originKey.screenId {
            guard let context = screenContexts[targetedKey.screenId],
                  context.zoneController.zone(at: targetedKey.index) != nil else {
                Logger.debug("Flip key window aborted: targeted zone \(targetedKey.index) unavailable on screen \(screenContextStore.loggingIndex(for: targetedKey.screenId))")
                return nil
            }
            return targetedKey
        }

        guard let destinationScreenId = firstAlternateScreenId(excluding: originKey.screenId) else {
            Logger.debug("Flip key window aborted: no alternate screen available")
            return nil
        }

        guard let destinationKey = preferredZoneKey(on: destinationScreenId) else {
            Logger.debug("Flip key window aborted: destination screen \(screenContextStore.loggingIndex(for: destinationScreenId)) has no zones")
            return nil
        }

        return destinationKey
    }

    /// Returns the first available display that is different from the given origin screen.
    private func firstAlternateScreenId(excluding screenId: CGDirectDisplayID) -> CGDirectDisplayID? {
        for candidateId in screenOrder where candidateId != screenId {
            if screenContexts[candidateId] != nil {
                return candidateId
            }
        }
        return nil
    }

}
