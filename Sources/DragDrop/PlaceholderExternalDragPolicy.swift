import Foundation

/// Pure policy helpers for deciding when placeholder external-drag UI may resume or promote.
enum PlaceholderExternalDragPolicy {
    static func shouldResumePlaceholderOverlay(
        isControlCommandHeld: Bool,
        isLeftMouseButtonDown: Bool,
        hasObservedRealPlaceholderExternalDrag: Bool
    ) -> Bool {
        guard !isControlCommandHeld,
              isLeftMouseButtonDown,
              hasObservedRealPlaceholderExternalDrag else {
            return false
        }
        return true
    }

    static func shouldPromotePlaceholderToInterceptedOverlay(
        isControlCommandHeld: Bool,
        hasObservedRealPlaceholderExternalDrag: Bool
    ) -> Bool {
        guard isControlCommandHeld,
              hasObservedRealPlaceholderExternalDrag else {
            return false
        }
        return true
    }
}
