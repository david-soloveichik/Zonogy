import Foundation
import AppKit

/// Represents a zone in the window manager
class Zone {
    /// The index of this zone (1-based)
    var index: Int

    /// The frame (position and size) for this zone
    var frame: CGRect

    /// The ID of the window currently occupying this zone, or nil if empty
    var windowId: Int?

    /// The ID of the placeholder window associated with this zone, or nil if none
    var placeholderWindowId: Int?

    init(index: Int, frame: CGRect, windowId: Int? = nil, placeholderWindowId: Int? = nil) {
        self.index = index
        self.frame = frame
        self.windowId = windowId
        self.placeholderWindowId = placeholderWindowId
    }

    var isEmpty: Bool {
        return windowId == nil
    }
}
