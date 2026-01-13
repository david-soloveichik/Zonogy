import Foundation

/// Top-level configuration for Zonogy, loaded from ~/Library/Application Support/Zonogy/config.json.
/// If config.json doesn't exist, it's created at startup with bundled defaults (see ExceptionsConfigurationStore).
struct Configuration {
    private struct FileContents: Decodable {
        let ignoredBundleIdentifiers: [String]?
        let bundleExceptions: [ApplicationExceptionRule]?
    }

    let ignoredBundleIdentifiers: Set<String>
    let applicationExceptionPolicy: ApplicationExceptionPolicy

    static func load(fileManager: FileManager = .default) -> Configuration {
        let config = loadUserConfig(fileManager: fileManager)

        var ignoredBundles = Set(config?.ignoredBundleIdentifiers ?? [])

        // Always ignore Zonogy's own bundle identifier
        if let ownBundleId = Bundle.main.bundleIdentifier {
            ignoredBundles.insert(ownBundleId)
            Logger.debug("Automatically ignoring own bundle identifier: \(ownBundleId)")
        }

        let exceptionRules = config?.bundleExceptions ?? []
        let exceptionPolicy = ApplicationExceptionPolicy(rules: exceptionRules)

        Logger.debug("Loaded configuration with \(ignoredBundles.count) ignored bundles, \(exceptionRules.count) exception rules")
        return Configuration(
            ignoredBundleIdentifiers: ignoredBundles,
            applicationExceptionPolicy: exceptionPolicy
        )
    }

    /// Loads configuration from ~/Library/Application Support/Zonogy/config.json
    private static func loadUserConfig(fileManager: FileManager) -> FileContents? {
        let userConfigURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zonogy/config.json")

        guard fileManager.fileExists(atPath: userConfigURL.path) else {
            Logger.debug("No config.json found at \(userConfigURL.path)")
            return nil
        }
        guard let data = try? Data(contentsOf: userConfigURL),
              let decoded = try? JSONDecoder().decode(FileContents.self, from: data) else {
            Logger.debug("Failed to decode config.json at \(userConfigURL.path)")
            return nil
        }
        Logger.debug("Loaded config from \(userConfigURL.path)")
        return decoded
    }
}
