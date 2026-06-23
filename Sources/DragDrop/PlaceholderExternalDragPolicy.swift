import Foundation

/// Pure policy helpers for deciding when placeholder external-drag UI may resume or promote.
enum PlaceholderExternalDragPolicy {
    static func shouldResumePlaceholderOverlay(
        gestureModifiersHeld: Bool,
        isLeftMouseButtonDown: Bool,
        hasObservedRealPlaceholderExternalDrag: Bool
    ) -> Bool {
        guard !gestureModifiersHeld,
              isLeftMouseButtonDown,
              hasObservedRealPlaceholderExternalDrag else {
            return false
        }
        return true
    }

    static func shouldPromotePlaceholderToInterceptedOverlay(
        gestureModifiersHeld: Bool,
        hasObservedRealPlaceholderExternalDrag: Bool
    ) -> Bool {
        guard gestureModifiersHeld,
              hasObservedRealPlaceholderExternalDrag else {
            return false
        }
        return true
    }
}
