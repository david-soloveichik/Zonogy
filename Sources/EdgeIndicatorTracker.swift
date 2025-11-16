import CoreGraphics

/// Tracks edge-indicator hit areas and drag-highlight state so multiple presenters can share logic.
final class EdgeIndicatorTracker {
    private(set) var hitAreas: [CGDirectDisplayID: CGRect] = [:]
    private(set) var highlightedScreenId: CGDirectDisplayID?

    /// Replace the set of hit areas. Clears the highlight if the previous screen no longer exists.
    func updateHitAreas(_ newAreas: [CGDirectDisplayID: CGRect]) {
        hitAreas = newAreas
        if let highlighted = highlightedScreenId,
           hitAreas[highlighted] == nil {
            highlightedScreenId = nil
        }
    }

    /// Returns whether the highlight changed.
    @discardableResult
    func setHighlightedScreen(_ screenId: CGDirectDisplayID?) -> Bool {
        if highlightedScreenId == screenId {
            return false
        }
        highlightedScreenId = screenId
        return true
    }
}
