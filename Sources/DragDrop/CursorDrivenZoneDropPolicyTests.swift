import Foundation
import CoreGraphics

/// Guardrail tests for cursor-driven tiling-zone highlight/drop filtering.
enum CursorDrivenZoneDropPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true
        let screen0: CGDirectDisplayID = 1
        let emptyZone = ZoneKey(screenId: screen0, index: 1)
        let occupiedZone = ZoneKey(screenId: screen0, index: 2)

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("CursorDrivenZoneDropPolicyTests: \(message)")
                allPassed = false
            }
        }

        assert(
            CursorDrivenZoneDropPolicy.effectiveTilingZoneHover(
                hoveredZoneKey: emptyZone,
                hoveredZoneIsEmpty: true,
                isControlCommandHeld: false,
                policy: .emptyZonesOnlyUnlessControlCommand
            ) == emptyZone,
            "expected empty zones to remain draggable without Control-Command"
        )

        assert(
            CursorDrivenZoneDropPolicy.effectiveTilingZoneHover(
                hoveredZoneKey: occupiedZone,
                hoveredZoneIsEmpty: false,
                isControlCommandHeld: false,
                policy: .emptyZonesOnlyUnlessControlCommand
            ) == nil,
            "expected occupied zones to stay unhighlighted without Control-Command"
        )

        assert(
            CursorDrivenZoneDropPolicy.effectiveTilingZoneHover(
                hoveredZoneKey: occupiedZone,
                hoveredZoneIsEmpty: false,
                isControlCommandHeld: true,
                policy: .emptyZonesOnlyUnlessControlCommand
            ) == occupiedZone,
            "expected occupied zones to become valid when Control-Command is held"
        )

        assert(
            CursorDrivenZoneDropPolicy.effectiveTilingZoneHover(
                hoveredZoneKey: occupiedZone,
                hoveredZoneIsEmpty: false,
                isControlCommandHeld: false,
                policy: .allZones
            ) == occupiedZone,
            "expected unrestricted drags to keep occupied-zone hover"
        )

        if allPassed {
            print("CursorDrivenZoneDropPolicyTests: all tests passed")
        }
        return allPassed
    }
}
