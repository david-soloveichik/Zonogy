import Foundation

/// Top-level configuration for Zonogy, loaded from bundled defaults merged with optional user overrides.
/// User config is loaded from ~/Library/Application Support/Zonogy/config.json.
/// User values override bundled defaults; arrays are merged (union for ignoredBundleIdentifiers,
/// merge-by-bundleId for bundleExceptions).
struct Configuration {
    private struct FileContents: Decodable {
        let ignoredBundleIdentifiers: [String]?
        let bundleExceptions: [ApplicationExceptionRule]?
    }

    let ignoredBundleIdentifiers: Set<String>
    let applicationExceptionPolicy: ApplicationExceptionPolicy

    static func load(fileManager: FileManager = .default) -> Configuration {
        let bundledDefaults = loadBundledDefaults()
        let userConfig = loadUserConfig(fileManager: fileManager)

        // Merge ignoredBundleIdentifiers (union)
        var mergedIgnored = Set(bundledDefaults?.ignoredBundleIdentifiers ?? [])
        mergedIgnored.formUnion(userConfig?.ignoredBundleIdentifiers ?? [])

        // Always ignore Zonogy's own bundle identifier
        if let ownBundleId = Bundle.main.bundleIdentifier {
            mergedIgnored.insert(ownBundleId)
            Logger.debug("Automatically ignoring own bundle identifier: \(ownBundleId)")
        }

        // Merge bundleExceptions by bundleIdentifier
        let mergedExceptions = mergeBundleExceptions(
            defaults: bundledDefaults?.bundleExceptions ?? [],
            userOverrides: userConfig?.bundleExceptions ?? []
        )

        let exceptionPolicy = ApplicationExceptionPolicy(rules: mergedExceptions)

        Logger.debug("Loaded configuration with \(mergedIgnored.count) ignored bundles, \(mergedExceptions.count) exception rules")
        return Configuration(
            ignoredBundleIdentifiers: mergedIgnored,
            applicationExceptionPolicy: exceptionPolicy
        )
    }

    /// Loads bundled default configuration from Resources/defaults.json
    /// Searches multiple filesystem locations since SwiftPM doesn't bundle resources automatically.
    private static func loadBundledDefaults() -> FileContents? {
        let fileName = "defaults.json"
        let executablePath = ProcessInfo.processInfo.arguments[0] as NSString

        let searchPaths = [
            // Resources directory relative to working directory (for development)
            "Resources/\(fileName)",
            // Resources directory relative to executable (for deployed binary)
            executablePath.deletingLastPathComponent + "/../Resources/\(fileName)",
            // Same directory as executable
            executablePath.deletingLastPathComponent + "/\(fileName)"
        ]

        for path in searchPaths {
            let expandedPath = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
               let decoded = try? JSONDecoder().decode(FileContents.self, from: data) {
                Logger.debug("Loaded bundled defaults from \(expandedPath)")
                return decoded
            }
        }

        Logger.debug("No bundled defaults.json found in any search path")
        return nil
    }

    /// Loads user configuration from ~/Library/Application Support/Zonogy/config.json
    private static func loadUserConfig(fileManager: FileManager) -> FileContents? {
        let userConfigURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zonogy/config.json")

        guard fileManager.fileExists(atPath: userConfigURL.path) else {
            Logger.debug("No user config.json found at \(userConfigURL.path)")
            return nil
        }
        guard let data = try? Data(contentsOf: userConfigURL),
              let decoded = try? JSONDecoder().decode(FileContents.self, from: data) else {
            Logger.debug("Failed to decode user config.json at \(userConfigURL.path)")
            return nil
        }
        Logger.debug("Loaded user config from \(userConfigURL.path)")
        return decoded
    }

    /// Merges bundleExceptions by bundleIdentifier.
    /// User overrides extend/replace default rules for the same bundle ID.
    private static func mergeBundleExceptions(
        defaults: [ApplicationExceptionRule],
        userOverrides: [ApplicationExceptionRule]
    ) -> [ApplicationExceptionRule] {
        var rulesByBundleId: [String: ApplicationExceptionRule] = [:]

        // Add defaults first
        for rule in defaults {
            rulesByBundleId[rule.bundleIdentifier] = rule
        }

        // User overrides merge with existing rules or add new ones
        for userRule in userOverrides {
            if let existing = rulesByBundleId[userRule.bundleIdentifier] {
                rulesByBundleId[userRule.bundleIdentifier] = existing.merged(with: userRule)
            } else {
                rulesByBundleId[userRule.bundleIdentifier] = userRule
            }
        }

        return rulesByBundleId.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }
}
