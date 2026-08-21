/// Represents a window in the launcher window list, enumerated via Accessibility API

import AppKit
import Foundation

struct LauncherWindowItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// Whether this window is currently placed in a zone (tiled or floating).
    /// Windows not placed in any zone are considered minimized. Mutable so open
    /// choosers can refresh it in place (see `refreshingPlacement`).
    var isPlacedInZone: Bool
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

    /// Must include `isPlacedInZone`, not just identity: the refresh publish gates compare
    /// old and new rows, and SwiftUI compares row items before repainting, so an id-only
    /// equality would make placement refreshes invisible at both levels.
    static func == (lhs: LauncherWindowItem, rhs: LauncherWindowItem) -> Bool {
        lhs.id == rhs.id && lhs.isPlacedInZone == rhs.isPlacedInZone
    }
}

extension Array where Element == LauncherWindowItem {
    /// Returns the same rows with each managed row's placed-in-zone flag re-read through
    /// the resolver. Membership and order are preserved so an open chooser never reorders
    /// under the user; rows without a managed id keep their snapshot value.
    func refreshingPlacement(isPlacedInZone: (Int) -> Bool) -> [LauncherWindowItem] {
        map { item in
            guard let managedWindowId = item.managedWindowId else { return item }
            var updated = item
            updated.isPlacedInZone = isPlacedInZone(managedWindowId)
            return updated
        }
    }
}
