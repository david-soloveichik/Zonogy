/// Creates LaunchItem values from filesystem URLs and display-name configuration.

import AppKit
import Foundation

enum LaunchItemBuilder {
    static func makeItem(for url: URL, displayNameStyle: AppDisplayNameStyle, alias: String? = nil) -> LaunchItem? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()

        let kind: LaunchItemKind
        if resolved.pathExtension.lowercased() == "app" {
            kind = .application
        } else if (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            kind = .directory
        } else {
            kind = .file
        }

        let displayName: String
        switch kind {
        case .application:
            guard let name = AppBundleInfo.displayName(for: resolved, style: displayNameStyle) else { return nil }
            displayName = name
        case .directory, .file:
            displayName = resolved.lastPathComponent
        }

        return LaunchItem(
            url: resolved,
            displayName: displayName,
            icon: NSWorkspace.shared.icon(forFile: resolved.path),
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
