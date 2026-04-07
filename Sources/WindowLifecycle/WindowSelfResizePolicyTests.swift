import Foundation

/// Guardrail tests for how snap-exception resize events interact with Sticky Resize tracking.
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

        if allPassed {
            print("WindowSelfResizePolicyTests: all tests passed")
        }
        return allPassed
    }
}
