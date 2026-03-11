/// Represents a window in the launcher window list, enumerated via Accessibility API

import AppKit
import Foundation

struct LauncherWindowItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// Whether this window is currently placed in a zone (tiled or floating).
    /// Windows not placed in any zone are considered minimized.
    let isPlacedInZone: Bool
    let axElement: AXUIElement
    let lastActiveTime: Date?
    let bundleIdentifier: String?
    let pid: pid_t
    /// If this window is managed by Zonogy, this is its windowId
    let managedWindowId: Int?

    init(
        title: String,
        isPlacedInZone: Bool = false,
        axElement: AXUIElement,
        lastActiveTime: Date? = nil,
        bundleIdentifier: String? = nil,
        pid: pid_t,
        managedWindowId: Int? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.isPlacedInZone = isPlacedInZone
        self.axElement = axElement
        self.lastActiveTime = lastActiveTime
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.managedWindowId = managedWindowId
    }

    static func == (lhs: LauncherWindowItem, rhs: LauncherWindowItem) -> Bool {
        lhs.id == rhs.id
    }
}
