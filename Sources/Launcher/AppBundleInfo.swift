/// Extracts display name and icon for an application bundle URL.

import AppKit
import Foundation

enum AppBundleInfo {
    /// Returns the display name for an app, matching what Finder/Dock shows.
    static func displayName(for url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") {
            return String(name.dropLast(4))
        }
        return name
    }
}
