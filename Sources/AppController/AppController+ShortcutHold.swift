import Foundation
import AppKit

/// Hold-to-perform-both for the paired shortcuts (Clear/Reset Zones, Minimize Focused Window,
/// Minimize/Remove Zone at Cursor). The press performs its first action immediately as always;
/// this extension arms the paired follow-up `ShortcutHoldPolicy` derives from the press outcome,
/// cancels it when the chord is released early or another shortcut fires, and performs it if the
/// chord is still held once `ShortcutHoldPolicy.followUpDelay` elapses.
extension AppController {

    struct PendingShortcutHoldFollowUp {
        let action: HotkeyService.Action
        let followUp: ShortcutHoldPolicy.FollowUp
        let workItem: DispatchWorkItem
    }

    /// Arms the paired follow-up for a hold-capable shortcut press, replacing any pending one.
    /// Presses whose outcome pairs with nothing (see `ShortcutHoldPolicy.followUp`) arm nothing.
    internal func armShortcutHoldFollowUp(
        action: HotkeyService.Action,
        outcome: ShortcutHoldPolicy.PressOutcome
    ) {
        guard let followUp = ShortcutHoldPolicy.followUp(for: outcome) else {
            return
        }

        cancelShortcutHoldFollowUp(reason: "rearm")
        let workItem = DispatchWorkItem { [weak self] in
            self?.fireShortcutHoldFollowUp()
        }
        pendingShortcutHoldFollowUp = PendingShortcutHoldFollowUp(
            action: action,
            followUp: followUp,
            workItem: workItem
        )
        Logger.debug("Shortcut hold: armed \(followUp) for \(action)")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ShortcutHoldPolicy.followUpDelay,
            execute: workItem
        )
    }

    /// Cancels any pending follow-up (chord released early, another shortcut fired, ...).
    internal func cancelShortcutHoldFollowUp(reason: String) {
        guard let pending = pendingShortcutHoldFollowUp else {
            return
        }
        pending.workItem.cancel()
        pendingShortcutHoldFollowUp = nil
        Logger.debug("Shortcut hold: cancelled pending follow-up for \(pending.action) (\(reason))")
    }

    /// Chord release for `action`: drop its pending follow-up. Releases of other chords are
    /// unrelated (e.g. a stale release arriving after another shortcut already replaced the
    /// pending follow-up).
    internal func handleShortcutHoldRelease(_ action: HotkeyService.Action) {
        guard pendingShortcutHoldFollowUp?.action == action else {
            return
        }
        cancelShortcutHoldFollowUp(reason: "chord-released")
    }

    /// The tiling zone `managed` occupies, for capturing what a minimize press vacates.
    internal func tiledVacatedZone(for managed: ManagedWindow) -> ShortcutHoldPolicy.VacatedZone? {
        guard !managed.isInFloatingZone,
              let zoneIndex = managed.zoneIndex,
              let screenId = managed.screenDisplayId ?? detectScreenId(for: managed) else {
            return nil
        }
        return ShortcutHoldPolicy.VacatedZone(
            screenId: screenId,
            zoneIndex: zoneIndex,
            windowId: managed.windowId
        )
    }

    private func fireShortcutHoldFollowUp() {
        guard let pending = pendingShortcutHoldFollowUp else {
            return
        }
        pendingShortcutHoldFollowUp = nil

        // Belt for a release the event path missed: never fire once the chord is up. The chord
        // being up also proves any Carbon held mark for it is stale; repair it so later presses
        // are not swallowed as autorepeats.
        guard hotkeyService.isShortcutChordPhysicallyDown(for: pending.action) else {
            Logger.debug("Shortcut hold: chord no longer held for \(pending.action); skipping follow-up")
            hotkeyService.clearHeldMark(for: pending.action)
            return
        }

        switch pending.followUp {
        case .resetZonesAfterClear(let screenId):
            guard let context = screenContexts[screenId],
                  context.zoneController.allZones.allSatisfy({ $0.isEmpty }) else {
                Logger.debug(
                    "Shortcut hold: clear did not leave all zones empty on screen \(screenContextStore.loggingIndex(for: screenId)); skipping reset"
                )
                return
            }
            Logger.debug(
                "Shortcut hold: resetting zones after clear on screen \(screenContextStore.loggingIndex(for: screenId))"
            )
            _ = clearOrResetZones(on: screenId, reason: "shortcut-hold-reset")
        case .removeVacatedZone(let vacatedZone):
            guard let context = screenContexts[vacatedZone.screenId],
                  let zone = context.zoneController.zone(at: vacatedZone.zoneIndex) else {
                Logger.debug("Shortcut hold: vacated zone \(vacatedZone.zoneIndex) no longer exists; skipping removal")
                return
            }
            // Zone bookkeeping can lag the AX miniaturize confirmation; when the zone still
            // shows the minimized window, ask AX whether it really is minimized (an app can
            // decline the request, and its zone must not vanish under a visible window).
            let occupantIsMinimized: Bool = {
                guard !zone.isEmpty,
                      zone.occupantWindowId == vacatedZone.windowId,
                      let managed = windowController.window(withId: vacatedZone.windowId) else {
                    return false
                }
                return windowController.isWindowMinimized(managed.backing.element)
            }()
            guard ShortcutHoldPolicy.removeVacatedZoneAllowed(
                zoneCountOnScreen: context.zoneController.allZones.count,
                vacatedZoneIsEmpty: zone.isEmpty,
                vacatedZoneOccupantWindowId: zone.occupantWindowId,
                minimizedWindowId: vacatedZone.windowId,
                occupantIsMinimized: occupantIsMinimized
            ) else {
                Logger.debug(
                    "Shortcut hold: vacated zone \(vacatedZone.zoneIndex) on screen \(screenContextStore.loggingIndex(for: vacatedZone.screenId)) not removable; skipping removal"
                )
                return
            }
            Logger.debug(
                "Shortcut hold: removing vacated zone \(vacatedZone.zoneIndex) on screen \(screenContextStore.loggingIndex(for: vacatedZone.screenId))"
            )
            _ = performRemoveZone(at: vacatedZone.zoneIndex, on: vacatedZone.screenId, announce: false)
        }
    }
}
