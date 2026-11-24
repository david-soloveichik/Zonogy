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
        let addPill = AddZonePillKey(screenId: screen1, side: .left)
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
                hoveredAddZonePill: addPill,
                hoveredFloatingScreenId: nil
            ) == nil,
            "expected add-zone hover to suppress empty-zone auto-promotion hover"
        )

        assert(
            EdgePillDragPolicy.effectiveZoneHover(
                hoveredZoneKey: emptyZone,
                hoveredAddZonePill: nil,
                hoveredFloatingScreenId: screen2
            ) == nil,
            "expected floating-pill hover to suppress underlying zone hover"
        )

        assert(
            EdgePillDragPolicy.effectiveZoneHover(
                hoveredZoneKey: emptyZone,
                hoveredAddZonePill: nil,
                hoveredFloatingScreenId: nil
            ) == emptyZone,
            "expected zone hover to remain when no edge pill is hovered"
        )

        assert(
            EdgePillDragPolicy.dropDecision(
                hoveredAddZonePill: addPill,
                hoveredFloatingScreenId: screen2,
                hoveredZoneKey: emptyZone
            ) == .addZone(addPill),
            "expected add-zone drop to win over floating-pill and zone targets"
        )

        assert(
            EdgePillDragPolicy.dropDecision(
                hoveredAddZonePill: nil,
                hoveredFloatingScreenId: screen2,
                hoveredZoneKey: emptyZone
            ) == .floatingZone(screen2),
            "expected floating-pill drop to win over an underlying zone target"
        )

        assert(
            EdgePillDragPolicy.dropDecision(
                hoveredAddZonePill: nil,
                hoveredFloatingScreenId: nil,
                hoveredZoneKey: emptyZone
            ) == .zone(emptyZone),
            "expected zone drop when no edge pill is hovered"
        )

        assert(
            EdgePillDragPolicy.dropDecision(
                hoveredAddZonePill: nil,
                hoveredFloatingScreenId: nil,
                hoveredZoneKey: nil
            ) == .fallback,
            "expected fallback when nothing is hovered"
        )

        // Floating-zone hover: indicators (the targeted one first) win over floating windows.
        let bar0 = CGRect(x: 100, y: 990, width: 300, height: 10)
        let overlappingBar1 = CGRect(x: 350, y: 990, width: 300, height: 10)
        let window1 = CGRect(x: 200, y: 600, width: 500, height: 395)
        let bars = [screen0: bar0, screen1: overlappingBar1]

        assert(
            EdgePillDragPolicy.floatingTarget(
                at: CGPoint(x: 375, y: 995),
                indicatorHitAreas: bars,
                targetedScreenId: screen1
            ) == screen1,
            "expected the targeted floating indicator to win where indicators overlap"
        )

        assert(
            EdgePillDragPolicy.floatingTarget(
                at: CGPoint(x: 250, y: 992),
                indicatorHitAreas: bars,
                targetedScreenId: nil,
                floatingWindowFrames: [screen1: window1]
            ) == screen0,
            "expected a floating indicator to win over a floating window beneath it"
        )

        assert(
            EdgePillDragPolicy.floatingTarget(
                at: CGPoint(x: 300, y: 700),
                indicatorHitAreas: bars,
                targetedScreenId: screen0,
                floatingWindowFrames: [screen1: window1]
            ) == screen1,
            "expected a floating window to resolve its floating zone away from every indicator"
        )

        assert(
            EdgePillDragPolicy.floatingTarget(
                at: CGPoint(x: 50, y: 50),
                indicatorHitAreas: bars,
                targetedScreenId: screen0,
                floatingWindowFrames: [screen1: window1]
            ) == nil,
            "expected no floating zone away from every indicator and floating window"
        )

        if allPassed {
            print("EdgePillDragPolicyTests: all tests passed")
        }
        return allPassed
    }
}
