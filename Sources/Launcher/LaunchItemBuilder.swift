/// Creates LaunchItem values from filesystem URLs and display-name configuration.

import AppKit
import Foundation

enum LaunchItemBuilder {
    static func makeItem(for url: URL, alias: String? = nil, skipIcon: Bool = false) -> LaunchItem? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()

        let kind: LaunchItemKind
        if resolved.pathExtension.lowercased() == "app" {
            kind = .application
        } else if (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            kind = .directory
        } else {
            kind = .file
        }

        let displayName = AppBundleInfo.displayName(for: resolved)

        let icon: NSImage? = skipIcon ? nil : NSWorkspace.shared.icon(forFile: resolved.path)

        return LaunchItem(
            url: resolved,
            displayName: displayName,
            icon: icon,
            kind: kind,
            alias: alias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
