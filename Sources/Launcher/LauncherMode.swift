/// Represents the current mode of the launcher UI

import Foundation

enum LauncherMode {
    case appList
    case windowList(bundleIdentifier: String, appName: String)
}
