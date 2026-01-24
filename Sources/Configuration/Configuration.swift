import Foundation

/// Top-level configuration for Zonogy, loaded from ~/Library/Application Support/Zonogy/config.json.
/// If config.json doesn't exist, it's created at startup with bundled defaults (see ExceptionsConfigurationStore).
struct Configuration {
    private struct FileContents: Decodable {
        let ignoredBundleIdentifiers: [String]?
        let bundleExceptions: [ApplicationExceptionRule]?
        let deriveBundleIdFromPathForProcesses: [String]?
    }

    let ignoredBundleIdentifiers: Set<String>
    let applicationExceptionPolicy: ApplicationExceptionPolicy
    /// Process names (executable names) for which we derive the bundle ID by walking up
    /// the executable path to find a containing .app or .bundle directory.
    /// Useful for Java apps (e.g., Minecraft) launched from a JRE bundle.
    let deriveBundleIdFromPathForProcesses: Set<String>

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

        let deriveBundleProcesses = Set(config?.deriveBundleIdFromPathForProcesses ?? [])

        Logger.debug("Loaded configuration with \(ignoredBundles.count) ignored bundles, \(exceptionRules.count) exception rules, \(deriveBundleProcesses.count) bundle-derived processes")
        return Configuration(
            ignoredBundleIdentifiers: ignoredBundles,
            applicationExceptionPolicy: exceptionPolicy,
            deriveBundleIdFromPathForProcesses: deriveBundleProcesses
        )
    }

    /// Derives the bundle identifier by walking up from the executable path to find a
    /// containing .app or .bundle directory and reading its Info.plist.
    /// Returns nil if no bundle is found or if the bundle has no CFBundleIdentifier.
    static func deriveBundleId(fromExecutableURL executableURL: URL) -> String? {
        var url = executableURL.deletingLastPathComponent()

        // Walk up the path looking for a .app or .bundle directory
        while url.path != "/" {
            let ext = url.pathExtension.lowercased()
            if ext == "app" || ext == "bundle" {
                // Found a bundle directory - try to read its Info.plist
                let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: infoPlistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let bundleId = plist["CFBundleIdentifier"] as? String {
                    return bundleId
                }
            }
            url = url.deletingLastPathComponent()
        }

        return nil
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
