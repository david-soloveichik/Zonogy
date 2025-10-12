import Foundation
import AppKit

/// Represents a window managed by the window manager
class ManagedWindow {
    /// Unique identifier for this window
    let windowId: Int

    /// The AppKit window reference
    let window: NSWindow

    /// Whether this is a placeholder window for an empty zone
    let isPlaceholder: Bool

    /// The zone index this window is currently assigned to, or nil if minimized
    var zoneIndex: Int?

    init(windowId: Int, window: NSWindow, isPlaceholder: Bool) {
        self.windowId = windowId
        self.window = window
        self.isPlaceholder = isPlaceholder
        self.zoneIndex = nil
    }

    var actualFrame: CGRect {
        return window.frame
    }

    var isMinimized: Bool {
        return window.isMiniaturized
    }
}
