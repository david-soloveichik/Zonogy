/// Immutable representation of a selectable, launchable item shown in the list.

import AppKit
import Foundation

struct LaunchItem: Identifiable {
    let url: URL
    let displayName: String
    let icon: NSImage?
    let kind: LaunchItemKind
    let alias: String?

    var id: URL { url }
}
