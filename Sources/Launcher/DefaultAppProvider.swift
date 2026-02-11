/// Discovers installed applications by scanning standard macOS application locations.

import AppKit
import Foundation

struct DefaultAppProvider: AppProviding {
    static func standardApplicationRoots(fileManager: FileManager = .default) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// Apps in non-standard locations that should always be included
    private static let explicitApps: [URL] = [
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
    ]

    func discoverApplications(skipIcons: Bool = false) async -> [LaunchItem] {
        let candidateRoots = Self.standardApplicationRoots()

        var seen: Set<String> = []
        var results: [LaunchItem] = []

        for root in candidateRoots where FileManager.default.fileExists(atPath: root.path) {
            results.append(contentsOf: discoverApps(under: root, skipIcons: skipIcons, seenPaths: &seen))
        }

        // Add explicit apps that live outside standard directories
        for url in Self.explicitApps where FileManager.default.fileExists(atPath: url.path) {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted else { continue }
            if let item = LaunchItemBuilder.makeItem(for: resolved, skipIcon: skipIcons) {
                results.append(item)
            }
        }

        return results
    }

    private func discoverApps(under root: URL, skipIcons: Bool, seenPaths: inout Set<String>) -> [LaunchItem] {
        var apps: [LaunchItem] = []

        // First pass: scan top-level contents using the path-based API.
        // The URL-based contentsOfDirectory(at:) has a known issue (SR-6707) where it
        // silently omits symlinks pointing to certain locations, notably Cryptexes
        // (e.g., Safari.app → /System/Volumes/Preboot/Cryptexes/...).
        if let topLevelNames = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for name in topLevelNames where !name.hasPrefix(".") {
                let url = root.appendingPathComponent(name)
                guard url.pathExtension.lowercased() == "app" else { continue }
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
                guard seenPaths.insert(resolved.path).inserted else { continue }
                if let item = LaunchItemBuilder.makeItem(for: resolved, skipIcon: skipIcons) {
                    apps.append(item)
                }
            }
        }

        // Second pass: use enumerator for recursive discovery in subdirectories.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: options)

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "app" else { continue }

            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seenPaths.insert(resolved.path).inserted else { continue }

            if let item = LaunchItemBuilder.makeItem(for: resolved, skipIcon: skipIcons) {
                apps.append(item)
            }
        }

        return apps
    }
}
