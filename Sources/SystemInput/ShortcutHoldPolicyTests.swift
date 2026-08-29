import Foundation

/// Lightweight runtime assertions for the hold-to-perform-both shortcut semantics.
enum ShortcutHoldPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ShortcutHoldPolicyTests: \(message)")
                allPassed = false
            }
        }

        let vacated = ShortcutHoldPolicy.VacatedZone(screenId: 1, zoneIndex: 2, windowId: 42)

        assert(
            ShortcutHoldPolicy.followUp(for: .clearedZones(screenId: 7)) == .resetZonesAfterClear(screenId: 7),
            "a clear press should arm a reset follow-up on the same display"
        )
        assert(
            ShortcutHoldPolicy.followUp(for: .resetZones) == nil,
            "a press that already reset should arm nothing"
        )
        assert(
            ShortcutHoldPolicy.followUp(for: .removedZone) == nil,
            "a press that already removed a zone should arm nothing"
        )
        assert(
            ShortcutHoldPolicy.followUp(for: .minimizedWindow(vacatedZone: vacated)) == .removeVacatedZone(vacated),
            "minimizing a tiled window should arm removal of its vacated zone"
        )
        assert(
            ShortcutHoldPolicy.followUp(for: .minimizedWindow(vacatedZone: nil)) == nil,
            "minimizing a floating or unzoned window should arm nothing"
        )
        assert(
            ShortcutHoldPolicy.followUp(for: .noAction) == nil,
            "a press that did nothing should arm nothing"
        )

        assert(
            ShortcutHoldPolicy.removeVacatedZoneAllowed(
                zoneCountOnScreen: 2,
                vacatedZoneIsEmpty: true,
                vacatedZoneOccupantWindowId: nil,
                minimizedWindowId: 42,
                occupantIsMinimized: false
            ),
            "an empty vacated zone should be removable"
        )
        assert(
            !ShortcutHoldPolicy.removeVacatedZoneAllowed(
                zoneCountOnScreen: 1,
                vacatedZoneIsEmpty: true,
                vacatedZoneOccupantWindowId: nil,
                minimizedWindowId: 42,
                occupantIsMinimized: false
            ),
            "the display's only zone should never be removed"
        )
        assert(
            ShortcutHoldPolicy.removeVacatedZoneAllowed(
                zoneCountOnScreen: 3,
                vacatedZoneIsEmpty: false,
                vacatedZoneOccupantWindowId: 42,
                minimizedWindowId: 42,
                occupantIsMinimized: true
            ),
            "a zone bookkept to the minimizing window that AX confirms minimized should be removable"
        )
        assert(
            !ShortcutHoldPolicy.removeVacatedZoneAllowed(
                zoneCountOnScreen: 3,
                vacatedZoneIsEmpty: false,
                vacatedZoneOccupantWindowId: 42,
                minimizedWindowId: 42,
                occupantIsMinimized: false
            ),
            "a zone whose window declined or has not completed the minimize should not be removed"
        )
        assert(
            !ShortcutHoldPolicy.removeVacatedZoneAllowed(
                zoneCountOnScreen: 3,
                vacatedZoneIsEmpty: false,
                vacatedZoneOccupantWindowId: 99,
                minimizedWindowId: 42,
                occupantIsMinimized: true
            ),
            "a zone re-occupied by a different window should not be removed"
        )

        if allPassed {
            print("ShortcutHoldPolicyTests: all tests passed")
        }
        return allPassed
    }
}
