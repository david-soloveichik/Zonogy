import AppKit

/// Typed drag payloads initiated from Launcher rows.
enum LauncherDragPayload {
    case managedWindow(LauncherWindowItem)
    case application(LaunchItem)
    case launchableItem(LaunchItem)

    var previewTitle: String {
        switch self {
        case .managedWindow(let window):
            return window.title
        case .application(let item), .launchableItem(let item):
            return item.displayName
        }
    }
}
