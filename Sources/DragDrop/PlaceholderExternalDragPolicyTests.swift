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
                isControlCommandHeld: false,
                isLeftMouseButtonDown: true,
                hasObservedRealPlaceholderExternalDrag: false
            ),
            "expected resume overlay to stay hidden until a real placeholder external drag has been observed"
        )

        assert(
            PlaceholderExternalDragPolicy.shouldResumePlaceholderOverlay(
                isControlCommandHeld: false,
                isLeftMouseButtonDown: true,
                hasObservedRealPlaceholderExternalDrag: true
            ),
            "expected resume overlay to be allowed for an observed placeholder external drag with the button still held"
        )

        assert(
            !PlaceholderExternalDragPolicy.shouldResumePlaceholderOverlay(
                isControlCommandHeld: true,
                isLeftMouseButtonDown: true,
                hasObservedRealPlaceholderExternalDrag: true
            ),
            "expected resume overlay to stay hidden while Control-Command interception is active"
        )

        assert(
            PlaceholderExternalDragPolicy.shouldPromotePlaceholderToInterceptedOverlay(
                isControlCommandHeld: true,
                hasObservedRealPlaceholderExternalDrag: true
            ),
            "expected placeholder promotion to intercepted overlay once a real placeholder drag is observed"
        )

        assert(
            !PlaceholderExternalDragPolicy.shouldPromotePlaceholderToInterceptedOverlay(
                isControlCommandHeld: true,
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
