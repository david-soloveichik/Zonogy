import CoreGraphics
import Foundation

/// Guardrail tests for untracked managed-app window drags over edge pills.
enum UnmanagedWindowEdgeDragPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true
        let screen0: CGDirectDisplayID = 1
        let screen1: CGDirectDisplayID = 2

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("UnmanagedWindowEdgeDragPolicyTests: \(message)")
                allPassed = false
            }
        }

        assert(
            !UnmanagedWindowEdgeDragPolicy.hasActivated(
                originFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                latestFrame: CGRect(x: 3, y: 4, width: 100, height: 100),
                threshold: 6
            ),
            "expected movement below threshold to stay inactive"
        )

        assert(
            UnmanagedWindowEdgeDragPolicy.hasActivated(
                originFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                latestFrame: CGRect(x: 6, y: 0, width: 100, height: 100),
                threshold: 6
            ),
            "expected movement at threshold to activate"
        )

        assert(
            UnmanagedWindowEdgeDragPolicy.edgeDropTarget(
                hoveredAddZoneScreenId: screen0,
                hoveredFloatingScreenId: screen1
            ) == .addZone(screen0),
            "expected add-zone edge target to win over floating edge target"
        )

        assert(
            UnmanagedWindowEdgeDragPolicy.edgeDropTarget(
                hoveredAddZoneScreenId: nil,
                hoveredFloatingScreenId: screen1
            ) == .floatingZone(screen1),
            "expected floating-zone edge target when no add-zone target is hovered"
        )

        assert(
            UnmanagedWindowEdgeDragPolicy.edgeDropTarget(
                hoveredAddZoneScreenId: nil,
                hoveredFloatingScreenId: nil
            ) == nil,
            "expected no edge target when no edge pill is hovered"
        )

        if allPassed {
            print("UnmanagedWindowEdgeDragPolicyTests: all tests passed")
        }
        return allPassed
    }
}
