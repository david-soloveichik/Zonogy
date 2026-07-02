import CoreGraphics

/// Tracks edge-indicator hit areas and drag-highlight state so multiple presenters can share logic.
/// Keyed generically: floating-zone bars use a screen id, add-zone bars use (screen, side).
final class EdgeIndicatorTracker<Key: Hashable> {
    private(set) var hitAreas: [Key: CGRect] = [:]
    private(set) var highlighted: Key?

    /// Replace the set of hit areas. Clears the highlight if its key no longer exists.
    func updateHitAreas(_ newAreas: [Key: CGRect]) {
        hitAreas = newAreas
        if let highlighted, hitAreas[highlighted] == nil {
            self.highlighted = nil
        }
    }

    /// Returns whether the highlight changed.
    @discardableResult
    func setHighlighted(_ key: Key?) -> Bool {
        if highlighted == key {
            return false
        }
        highlighted = key
        return true
    }
}
