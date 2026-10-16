/// Manages loading and saving the exceptions portion of the user config.json file.
/// If config.json doesn't exist, it's created pre-filled with bundled defaults; an existing file
/// receives the defaults introduced since it was written, each default exception rule only once.

import Foundation

extension Notification.Name {
    static let exceptionsConfigurationDidChange = Notification.Name("ExceptionsConfigurationDidChange")
}

enum ExceptionsConfigurationStore {
    struct UserConfig: Codable, Equatable {
        var ignoredBundleIdentifiers: [String]?
        var deriveBundleIdFromPathForProcesses: [String]?
        var bundleExceptions: [ApplicationExceptionRule]?
        /// Apps whose default exception rule this file has already received, so a removed rule stays removed.
        var offeredDefaultExceptions: [String]?

        /// Adds the defaults this config has not received yet without overriding user-provided values:
        /// the process list when its key is missing, and each default exception rule once (skipped when
        /// the config already has a rule for that app). Returns whether anything changed.
        mutating func addMissingDefaults(from defaults: UserConfig) -> Bool {
            let original = self
            if deriveBundleIdFromPathForProcesses == nil {
                deriveBundleIdFromPathForProcesses = defaults.deriveBundleIdFromPathForProcesses ?? []
            }

            let defaultRules = defaults.bundleExceptions ?? []
            let offered = Set(offeredDefaultExceptions ?? [])
            let configured = Set((bundleExceptions ?? []).map(\.bundleIdentifier))
            let newRules = defaultRules.filter {
                !offered.contains($0.bundleIdentifier) && !configured.contains($0.bundleIdentifier)
            }
            if !newRules.isEmpty {
                bundleExceptions = (bundleExceptions ?? []) + newRules
            }
            offeredDefaultExceptions = offered.union(defaultRules.map(\.bundleIdentifier)).sorted()
            return self != original
        }
    }

    /// Returns the URL for the user config.json file
    static func configurationFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appending(path: "Zonogy", directoryHint: .isDirectory)
            .appending(path: "config.json", directoryHint: .notDirectory)
    }

    /// Ensures config.json exists and has the bundled defaults it has not received yet.
    /// Call this before loading the configuration so new defaults apply right away.
    static func ensureConfigExists() {
        guard let defaults = loadBundledDefaults() else {
            return
        }
        let fileURL = configurationFileURL()
        // A new file starts with the default ignored apps; addMissingDefaults supplies the rest
        // (and always reports a change for it, since a new file has no offered-defaults record yet).
        let newFile = UserConfig(ignoredBundleIdentifiers: defaults.ignoredBundleIdentifiers)
        guard var config = readConfig(at: fileURL, orIfMissing: newFile),
              config.addMissingDefaults(from: defaults) else {
            return
        }
        if write(config, to: fileURL) {
            Logger.debug("Added bundled defaults to config.json")
        }
    }

    /// Loads the Preferences > Exceptions rows from config.json.
    /// Creates the file with bundled defaults if it doesn't exist.
    static func loadEntries() -> [ExceptionsPreferencesEntry] {
        ensureConfigExists()

        guard let config = readConfig(at: configurationFileURL(), orIfMissing: UserConfig()) else {
            return []
        }
        return ExceptionsPreferencesEntry.buildEntries(
            rules: config.bundleExceptions ?? [],
            ignoredBundleIdentifiers: config.ignoredBundleIdentifiers ?? []
        )
    }

    /// Saves Preferences > Exceptions rows to config.json.
    /// Preserves any unrelated configuration fields already present in the file.
    static func saveEntries(_ entries: [ExceptionsPreferencesEntry]) {
        let fileURL = configurationFileURL()
        guard var config = readConfig(at: fileURL, orIfMissing: UserConfig()) else {
            Logger.error("Exceptions not saved: config.json fails to decode")
            return
        }

        let persisted = ExceptionsPreferencesEntry.splitForPersistence(entries)
        config.ignoredBundleIdentifiers = persisted.ignoredBundleIdentifiers.isEmpty
            ? nil
            : persisted.ignoredBundleIdentifiers
        config.bundleExceptions = persisted.rules.isEmpty ? nil : persisted.rules

        if write(config, to: fileURL) {
            // Notify observers that exception rules changed
            NotificationCenter.default.post(name: .exceptionsConfigurationDidChange, object: nil)
        }
    }

    /// Returns the decoded config.json, `fallback` if the file doesn't exist yet, or nil if it can't be
    /// read or decoded. Callers leave such a file alone rather than replace everything in it.
    private static func readConfig(at fileURL: URL, orIfMissing fallback: UserConfig) -> UserConfig? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return fallback
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(UserConfig.self, from: data)
    }

    /// Writes config.json, creating its directory if needed. Returns whether the write succeeded.
    private static func write(_ config: UserConfig, to fileURL: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(config).write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// Returns bundled defaults from Resources/defaults.json, or nil if the file can't be found or decoded.
    private static func loadBundledDefaults() -> UserConfig? {
        let fileName = "defaults.json"
        let executablePath = ProcessInfo.processInfo.arguments[0] as NSString

        let searchPaths = [
            "Resources/\(fileName)",
            executablePath.deletingLastPathComponent + "/../Resources/\(fileName)",
            executablePath.deletingLastPathComponent + "/\(fileName)"
        ]

        for path in searchPaths {
            let expandedPath = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
               let decoded = try? JSONDecoder().decode(UserConfig.self, from: data) {
                return decoded
            }
        }

        return nil
    }
}
