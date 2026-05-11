import AppKit

/// Typed drag payloads initiated from Launcher rows.
enum LauncherDragPayload {
    /// A specific managed window. `appURL` is non-nil when this payload was resolved from an
    /// application-row drag (where Option at drop should switch to a new-window action for
    /// that app); nil for direct window-list-mode drags where Option has no special meaning.
    case managedWindow(LauncherWindowItem, appURL: URL?)
    case application(LaunchItem)
    case launchableItem(LaunchItem)

    var previewTitle: String {
        switch self {
        case .managedWindow(let window, _):
            return window.title
        case .application(let item), .launchableItem(let item):
            return item.displayName
        }
    }
}
