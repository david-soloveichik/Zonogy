import Foundation

/// Guardrail tests for placeholder external-drag overlay promotion/resume gating.
enum PlaceholderExternalDragPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("PlaceholderExternalDragPolicyTests: \(message)")
                allPassed = false
            }
        }

        assert(
            !PlaceholderExternalDragPolicy.shouldResumePlaceholderOverlay(
                gestureModifiersHeld: false,
                isLeftMouseButtonDown: true,
                hasObservedRealPlaceholderExternalDrag: false
            ),
            "expected resume overlay to stay hidden until a real placeholder external drag has been observed"
        )

        assert(
            PlaceholderExternalDragPolicy.shouldResumePlaceholderOverlay(
                gestureModifiersHeld: false,
                isLeftMouseButtonDown: true,
                hasObservedRealPlaceholderExternalDrag: true
            ),
            "expected resume overlay to be allowed for an observed placeholder external drag with the button still held"
        )

        assert(
            !PlaceholderExternalDragPolicy.shouldResumePlaceholderOverlay(
                gestureModifiersHeld: true,
                isLeftMouseButtonDown: true,
                hasObservedRealPlaceholderExternalDrag: true
            ),
            "expected resume overlay to stay hidden while gesture-modifier interception is active"
        )

        assert(
            PlaceholderExternalDragPolicy.shouldPromotePlaceholderToInterceptedOverlay(
                gestureModifiersHeld: true,
                hasObservedRealPlaceholderExternalDrag: true
            ),
            "expected placeholder promotion to intercepted overlay once a real placeholder drag is observed"
        )

        assert(
            !PlaceholderExternalDragPolicy.shouldPromotePlaceholderToInterceptedOverlay(
                gestureModifiersHeld: true,
                hasObservedRealPlaceholderExternalDrag: false
            ),
            "expected placeholder promotion to be rejected for stale pasteboard-only gestures"
        )

        if allPassed {
            print("PlaceholderExternalDragPolicyTests: all tests passed")
        }
        return allPassed
    }
}
