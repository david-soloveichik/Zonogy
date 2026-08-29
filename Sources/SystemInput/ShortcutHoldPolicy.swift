import CoreGraphics
import Foundation

/// Semantics for holding one of the paired shortcuts (Clear/Reset Zones, Minimize Focused Window,
/// Minimize/Remove Zone at Cursor): a quick press performs the shortcut's usual first action, and
/// keeping the chord held past `followUpDelay` also performs the paired follow-up for whatever the
/// press acted on. The follow-up is bound at press time (display, zone, window) and never cascades:
/// a press that already performed the pair's second kind of action (reset, zone removal) arms
/// nothing. Pure decision logic so it stays guardrail-testable.
enum ShortcutHoldPolicy {

    /// How long the chord must stay held before the paired follow-up fires.
    static let followUpDelay: TimeInterval = 0.5

    /// The tiling zone a minimize press emptied, captured at press time.
    struct VacatedZone: Equatable {
        let screenId: CGDirectDisplayID
        let zoneIndex: Int
        let windowId: Int
    }

    /// What a press of one of the paired shortcuts actually did.
    enum PressOutcome: Equatable {
        /// Clear/Reset with occupied zones: every window on the display was minimized.
        case clearedZones(screenId: CGDirectDisplayID)
        /// Clear/Reset with already-empty zones: the display collapsed to one zone.
        case resetZones
        /// The press removed a zone directly (cursor over an empty zone, or Launcher open).
        case removedZone
        /// The press minimized a window; `vacatedZone` is nil for a floating or unzoned window.
        case minimizedWindow(vacatedZone: VacatedZone?)
        /// The press found nothing to act on.
        case noAction
    }

    /// The second half of the pair to perform if the chord is still held after `followUpDelay`.
    enum FollowUp: Equatable {
        /// Reset the cleared display to a one-zone configuration.
        case resetZonesAfterClear(screenId: CGDirectDisplayID)
        /// Remove the tiling zone the minimized window vacated.
        case removeVacatedZone(VacatedZone)
    }

    /// Maps what the press did to the follow-up a continued hold should perform, if any.
    static func followUp(for outcome: PressOutcome) -> FollowUp? {
        switch outcome {
        case .clearedZones(let screenId):
            return .resetZonesAfterClear(screenId: screenId)
        case .minimizedWindow(.some(let vacatedZone)):
            return .removeVacatedZone(vacatedZone)
        case .resetZones, .removedZone, .minimizedWindow(vacatedZone: nil), .noAction:
            return nil
        }
    }

    /// Whether the vacated zone may be removed when the follow-up fires. The zone must not be the
    /// display's only zone, and must be empty — or still held by the very window the press
    /// minimized, provided that window really is minimized by now (its AX miniaturize
    /// confirmation simply hasn't landed): an app can decline the minimize request, and its zone
    /// must not be pulled out from under a still-visible window.
    static func removeVacatedZoneAllowed(
        zoneCountOnScreen: Int,
        vacatedZoneIsEmpty: Bool,
        vacatedZoneOccupantWindowId: Int?,
        minimizedWindowId: Int,
        occupantIsMinimized: Bool
    ) -> Bool {
        guard zoneCountOnScreen > 1 else {
            return false
        }
        if vacatedZoneIsEmpty {
            // However it emptied, removing an empty zone cannot pull a zone out from under a
            // visible window — the harm the minimized check below guards against.
            return true
        }
        return vacatedZoneOccupantWindowId == minimizedWindowId && occupantIsMinimized
    }
}
