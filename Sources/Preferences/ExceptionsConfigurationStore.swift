/// Manages loading and saving the exceptions portion of the user config.json file.

import Foundation

enum ExceptionsConfigurationStore {
    private struct UserConfig: Codable {
        var ignoredBundleIdentifiers: [String]?
        var bundleExceptions: [ApplicationExceptionRule]?
    }

    /// Returns the URL for the user config.json file
    static func configurationFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appending(path: "Zonogy", directoryHint: .isDirectory)
            .appending(path: "config.json", directoryHint: .notDirectory)
    }

    /// Loads user-defined exception rules (not merged with bundled defaults).
    /// Returns only the rules explicitly defined by the user.
    static func loadUserRules() -> [ApplicationExceptionRule] {
        let fileURL = configurationFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(UserConfig.self, from: data) else {
            return []
        }
        return config.bundleExceptions ?? []
    }

    /// Saves user-defined exception rules to the user config.json file.
    /// Preserves any ignoredBundleIdentifiers that may already exist in the file.
    static func saveUserRules(_ rules: [ApplicationExceptionRule]) {
        let fileURL = configurationFileURL()
        let directoryURL = fileURL.deletingLastPathComponent()

        // Ensure directory exists
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        // Load existing config to preserve other fields
        var existingConfig: UserConfig = UserConfig()
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(UserConfig.self, from: data) {
            existingConfig = decoded
        }

        // Update exceptions
        existingConfig.bundleExceptions = rules.isEmpty ? nil : rules

        // Save
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(existingConfig) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    /// Returns the bundled default rules from Resources/defaults.json
    static func loadBundledDefaultRules() -> [ApplicationExceptionRule] {
        let fileName = "defaults.json"
        let executablePath = ProcessInfo.processInfo.arguments[0] as NSString

        let searchPaths = [
            "Resources/\(fileName)",
            executablePath.deletingLastPathComponent + "/../Resources/\(fileName)",
            executablePath.deletingLastPathComponent + "/\(fileName)"
        ]

        struct FileContents: Decodable {
            let bundleExceptions: [ApplicationExceptionRule]?
        }

        for path in searchPaths {
            let expandedPath = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
               let decoded = try? JSONDecoder().decode(FileContents.self, from: data) {
                return decoded.bundleExceptions ?? []
            }
        }

        return []
    }
}
