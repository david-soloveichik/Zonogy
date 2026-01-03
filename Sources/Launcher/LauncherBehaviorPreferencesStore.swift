/// Persists user-facing Launcher behavior preferences.

import Foundation

enum LauncherBehaviorPreferencesStore {
    struct Preferences: Codable {
        var autoShowLauncherForEmptyTilingZones: Bool

        init(autoShowLauncherForEmptyTilingZones: Bool) {
            self.autoShowLauncherForEmptyTilingZones = autoShowLauncherForEmptyTilingZones
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            autoShowLauncherForEmptyTilingZones = try container.decodeIfPresent(Bool.self, forKey: .autoShowLauncherForEmptyTilingZones) ?? true
        }
    }

    static func loadPreferences() -> Preferences? {
        let url = preferencesFileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    static func saveAutoShowLauncherForEmptyTilingZonesEnabled(_ enabled: Bool) {
        let url = preferencesFileURL()
        let directoryURL = url.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Preferences(autoShowLauncherForEmptyTilingZones: enabled)
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
            .appending(path: "launcher-preferences.json", directoryHint: .notDirectory)
    }
}

