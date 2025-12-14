/// Discovers installed applications by scanning standard macOS application locations.

import AppKit
import Foundation

struct DefaultAppProvider: AppProviding {
    func discoverApplications(displayNameStyle: AppDisplayNameStyle) async -> [LaunchItem] {
        let candidateRoots: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]

        var seen: Set<String> = []
        var results: [LaunchItem] = []

        for root in candidateRoots where FileManager.default.fileExists(atPath: root.path) {
            results.append(contentsOf: discoverApps(under: root, displayNameStyle: displayNameStyle, seenPaths: &seen))
        }

        return results
    }

    private func discoverApps(under root: URL, displayNameStyle: AppDisplayNameStyle, seenPaths: inout Set<String>) -> [LaunchItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: options)

        var apps: [LaunchItem] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "app" else { continue }

            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seenPaths.insert(resolved.path).inserted else { continue }

            if let item = LaunchItemBuilder.makeItem(for: resolved, displayNameStyle: displayNameStyle) {
                apps.append(item)
            }
        }

        return apps
    }
}
