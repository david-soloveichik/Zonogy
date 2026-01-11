import Foundation
import AppKit

/// Represents a zone in the window manager.
/// A zone can have an external window occupant and/or a placeholder.
/// - When empty: `occupantWindowId == nil`, placeholder may or may not be visible
/// - When occupied: `occupantWindowId != nil`, placeholder is hidden
class Zone {
    /// The index of this zone (1-based)
    var index: Int

    /// The frame (position and size) for this zone in screen coordinates
    var frame: CGRect

    /// The ID of the external window occupying this zone, or nil if empty.
    /// Only ManagedWindow instances (from other applications) can occupy zones.
    var occupantWindowId: Int?

    /// Direct reference to the placeholder window for this zone.
    /// Placeholders are owned by zones, not tracked in the window registry.
    var placeholder: PlaceholderWindow?

    init(index: Int, frame: CGRect, occupantWindowId: Int? = nil, placeholder: PlaceholderWindow? = nil) {
        self.index = index
        self.frame = frame
        self.occupantWindowId = occupantWindowId
        self.placeholder = placeholder
    }

    /// True if no external window occupies this zone.
    var isEmpty: Bool {
        return occupantWindowId == nil
    }

    /// True if zone is empty and has a visible placeholder.
    var hasVisiblePlaceholder: Bool {
        return isEmpty && placeholder?.isVisible == true
    }
}
