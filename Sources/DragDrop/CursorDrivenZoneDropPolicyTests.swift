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
                gestureModifiersHeld: false,
                policy: .emptyZonesOnlyUnlessGestureModifiers
            ) == emptyZone,
            "expected empty zones to remain draggable without the gesture modifiers"
        )

        assert(
            CursorDrivenZoneDropPolicy.effectiveTilingZoneHover(
                hoveredZoneKey: occupiedZone,
                hoveredZoneIsEmpty: false,
                gestureModifiersHeld: false,
                policy: .emptyZonesOnlyUnlessGestureModifiers
            ) == nil,
            "expected occupied zones to stay unhighlighted without the gesture modifiers"
        )

        assert(
            CursorDrivenZoneDropPolicy.effectiveTilingZoneHover(
                hoveredZoneKey: occupiedZone,
                hoveredZoneIsEmpty: false,
                gestureModifiersHeld: true,
                policy: .emptyZonesOnlyUnlessGestureModifiers
            ) == occupiedZone,
            "expected occupied zones to become valid when the gesture modifiers are held"
        )

        assert(
            CursorDrivenZoneDropPolicy.effectiveTilingZoneHover(
                hoveredZoneKey: occupiedZone,
                hoveredZoneIsEmpty: false,
                gestureModifiersHeld: false,
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
