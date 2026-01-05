/// Persists user-facing targeting mode preferences.

import Foundation

enum TargetingPreferencesStore {
    struct Preferences: Codable {
        var mode: TargetingMode

        init(mode: TargetingMode) {
            self.mode = mode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let raw = try container.decodeIfPresent(String.self, forKey: .mode),
               let decoded = TargetingMode(rawValue: raw) {
                mode = decoded
            } else {
                mode = .independentOfFocus
            }
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

    static func saveMode(_ mode: TargetingMode) {
        let url = preferencesFileURL()
        let directoryURL = url.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Preferences(mode: mode)
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
            .appending(path: "targeting-preferences.json", directoryHint: .notDirectory)
    }
}

