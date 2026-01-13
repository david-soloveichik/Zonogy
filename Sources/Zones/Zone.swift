import Foundation
import AppKit

/// Represents a zone in the window manager.
/// A zone can have an external window occupant; placeholders are managed by PlaceholderCoordinator.
/// - When empty: `occupantWindowId == nil`
/// - When occupied: `occupantWindowId != nil`
class Zone {
    /// The index of this zone (1-based)
    var index: Int

    /// The frame (position and size) for this zone in screen coordinates
    var frame: CGRect

    /// The ID of the external window occupying this zone, or nil if empty.
    /// Only ManagedWindow instances (from other applications) can occupy zones.
    var occupantWindowId: Int?

    init(index: Int, frame: CGRect, occupantWindowId: Int? = nil) {
        self.index = index
        self.frame = frame
        self.occupantWindowId = occupantWindowId
    }

    /// True if no external window occupies this zone.
    var isEmpty: Bool {
        return occupantWindowId == nil
    }
}
