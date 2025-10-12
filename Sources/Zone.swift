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

    init(index: Int, frame: CGRect, windowId: Int? = nil) {
        self.index = index
        self.frame = frame
        self.windowId = windowId
    }

    var isEmpty: Bool {
        return windowId == nil
    }
}
