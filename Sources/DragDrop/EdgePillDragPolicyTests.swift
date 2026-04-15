import Foundation
import CoreGraphics

/// Guardrail tests for precedence between edge pills and underlying zone targets.
enum EdgePillDragPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true
        let screen0: CGDirectDisplayID = 1
        let screen1: CGDirectDisplayID = 2
        let screen2: CGDirectDisplayID = 3
        let emptyZone = ZoneKey(screenId: screen0, index: 1)

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("EdgePillDragPolicyTests: \(message)")
                allPassed = false
            }
        }

        assert(
            EdgePillDragPolicy.effectiveZoneHover(
                hoveredZoneKey: emptyZone,
                hoveredAddZoneScreenId: screen1,
                hoveredFloatingScreenId: nil
            ) == nil,
            "expected add-zone hover to suppress empty-zone auto-promotion hover"
        )

        assert(
            EdgePillDragPolicy.effectiveZoneHover(
                hoveredZoneKey: emptyZone,
                hoveredAddZoneScreenId: nil,
                hoveredFloatingScreenId: screen2
            ) == nil,
            "expected floating-pill hover to suppress underlying zone hover"
        )

        assert(
            EdgePillDragPolicy.effectiveZoneHover(
                hoveredZoneKey: emptyZone,
                hoveredAddZoneScreenId: nil,
                hoveredFloatingScreenId: nil
            ) == emptyZone,
            "expected zone hover to remain when no edge pill is hovered"
        )

        assert(
            EdgePillDragPolicy.dropDecision(
                hoveredAddZoneScreenId: screen1,
                hoveredFloatingScreenId: screen2,
                hoveredZoneKey: emptyZone
            ) == .addZone(screen1),
            "expected add-zone drop to win over floating-pill and zone targets"
        )

        assert(
            EdgePillDragPolicy.dropDecision(
                hoveredAddZoneScreenId: nil,
                hoveredFloatingScreenId: screen2,
                hoveredZoneKey: emptyZone
            ) == .floatingZone(screen2),
            "expected floating-pill drop to win over an underlying zone target"
        )

        assert(
            EdgePillDragPolicy.dropDecision(
                hoveredAddZoneScreenId: nil,
                hoveredFloatingScreenId: nil,
                hoveredZoneKey: emptyZone
            ) == .zone(emptyZone),
            "expected zone drop when no edge pill is hovered"
        )

        assert(
            EdgePillDragPolicy.dropDecision(
                hoveredAddZoneScreenId: nil,
                hoveredFloatingScreenId: nil,
                hoveredZoneKey: nil
            ) == .fallback,
            "expected fallback when nothing is hovered"
        )

        if allPassed {
            print("EdgePillDragPolicyTests: all tests passed")
        }
        return allPassed
    }
}
