import Foundation

/// Guardrail tests for how snap-exception windows tell user edge drags from the app's own resizes,
/// and how those resize events interact with Sticky Resize tracking.
enum WindowSelfResizePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WindowSelfResizePolicyTests: \(message)")
                allPassed = false
            }
        }

        assert(
            WindowSelfResizePolicy.action(
                isAlreadyDetached: false,
                isLikelyUserResize: true
            ) == .updateManualResizeTracking,
            "fresh user edge drags should update Sticky Resize tracking"
        )

        assert(
            WindowSelfResizePolicy.action(
                isAlreadyDetached: true,
                isLikelyUserResize: true
            ) == .updateManualResizeTracking,
            "detached windows should keep updating Sticky Resize tracking while the user is still edge-dragging"
        )

        assert(
            WindowSelfResizePolicy.action(
                isAlreadyDetached: true,
                isLikelyUserResize: false
            ) == .ignoreWhileDetached,
            "detached windows should ignore later app-driven self-resizes"
        )

        assert(
            WindowSelfResizePolicy.action(
                isAlreadyDetached: false,
                isLikelyUserResize: false
            ) == .snapToZone,
            "non-user self-resizes should snap exception windows back to their zones"
        )

        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        let atRightEdge = CGPoint(x: 703, y: 300)
        let onInnerControl = CGPoint(x: 400, y: 450)
        func isUserResize(cursor: CGPoint, buttonDown: Bool, secondsSinceUp: TimeInterval) -> Bool {
            WindowResizeHeuristics.isLikelyUserEdgeDragResize(
                cursorPoint: cursor,
                windowFrame: frame,
                edgeProximity: 6,
                leftMouseButtonDown: buttonDown,
                secondsSinceLeftMouseUp: secondsSinceUp,
                mouseUpGrace: 0.35
            )
        }

        assert(
            isUserResize(cursor: CGPoint(x: 1100, y: 250), buttonDown: true, secondsSinceUp: 5),
            "a resize while the button is held should be the user's even when the reported frame trails the cursor (slow apps)"
        )
        assert(
            isUserResize(cursor: atRightEdge, buttonDown: false, secondsSinceUp: 0.1),
            "a resize just after release with the cursor at the window's edge should be the user's"
        )
        assert(
            !isUserResize(cursor: onInnerControl, buttonDown: false, secondsSinceUp: 0.1),
            "a resize just after a click inside the window (the app's own controls) should be the app's"
        )
        assert(
            !isUserResize(cursor: atRightEdge, buttonDown: false, secondsSinceUp: 1),
            "a resize long after release should be the app's even with the cursor at the edge"
        )

        if allPassed {
            print("WindowSelfResizePolicyTests: all tests passed")
        }
        return allPassed
    }
}
