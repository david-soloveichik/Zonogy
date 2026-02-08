/// Locates, creates, and loads the user-editable launcher configuration file.

import Foundation

enum LauncherConfigurationStore {
    struct Entry: Hashable, Sendable {
        let url: URL
        let alias: String?
    }

    static func loadEntries() -> [Entry] {
        ensureTemplateExists()

        let url = configurationFileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        if let config = try? decoder.decode(LauncherConfiguration.self, from: data) {
            return resolveEntries(from: config.items)
        }
        if let items = try? decoder.decode([LauncherConfigurationItem].self, from: data) {
            return resolveEntries(from: items)
        }

        return []
    }

    /// Loads the full configuration (items without path resolution).
    static func loadConfiguration() -> LauncherConfiguration {
        ensureTemplateExists()

        let url = configurationFileURL()
        guard let data = try? Data(contentsOf: url) else {
            return LauncherConfiguration(items: [])
        }

        let decoder = JSONDecoder()
        if let config = try? decoder.decode(LauncherConfiguration.self, from: data) {
            return config
        }
        if let items = try? decoder.decode([LauncherConfigurationItem].self, from: data) {
            return LauncherConfiguration(items: items)
        }

        return LauncherConfiguration(items: [])
    }

    /// Saves the configuration to disk.
    static func saveConfiguration(_ config: LauncherConfiguration) {
        let fileURL = configurationFileURL()
        let directoryURL = fileURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    private static func resolveEntries(from items: [LauncherConfigurationItem]) -> [Entry] {
        var results: [Entry] = []
        results.reserveCapacity(items.count)

        for item in items {
            let expanded = (item.path as NSString).expandingTildeInPath
            let candidate = URL(fileURLWithPath: expanded)

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { continue }

            results.append(Entry(url: candidate, alias: item.alias?.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return results
    }

    private static func ensureTemplateExists() {
        let fileURL = configurationFileURL()
        let directoryURL = fileURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let template = LauncherConfiguration(
            items: [
                LauncherConfigurationItem(path: "~/Downloads", alias: nil),
                LauncherConfigurationItem(path: "~/Documents", alias: nil),
                LauncherConfigurationItem(path: "/Applications", alias: nil),
            ],
            notes: "Add items as {\"path\": \"/path/to/file/or/directory\", \"alias\": \"optional\"}. Restart Zonogy to reload."
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(template) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    static func configurationFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appending(path: "Zonogy", directoryHint: .isDirectory)
            .appending(path: "launcher-config.json", directoryHint: .notDirectory)
    }
}
