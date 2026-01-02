/// Persists user-facing DockMenus enablement preferences.

import Foundation

enum DockMenusPreferencesStore {
    struct Preferences: Codable {
        var enabled: Bool
    }

    static func loadPreferences() -> Preferences? {
        let url = preferencesFileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    static func saveEnabled(_ enabled: Bool) {
        let url = preferencesFileURL()
        let directoryURL = url.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Preferences(enabled: enabled)
        guard let data = try? encoder.encode(payload) else {
            return
        }

        try? data.write(to: url, options: [.atomic])
    }

    static func preferencesFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appending(path: "Zonogy", directoryHint: .isDirectory)
            .appending(path: "dockmenus-preferences.json", directoryHint: .notDirectory)
    }
}

