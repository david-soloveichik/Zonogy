import Foundation

struct Configuration: Decodable {
    private struct FileContents: Decodable {
        let ignoredBundleIdentifiers: [String]?
    }

    private static let defaultIgnoredBundles: Set<String> = []

    let ignoredBundleIdentifiers: Set<String>

    static func load(fileManager: FileManager = .default) -> Configuration {
        let candidateURLs = configurationFileCandidates(fileManager: fileManager)

        // Always ignore Zonogy's own bundle identifier to prevent managing our own windows
        var finalIgnoredBundles = defaultIgnoredBundles
        if let ownBundleId = Bundle.main.bundleIdentifier {
            finalIgnoredBundles.insert(ownBundleId)
            Logger.debug("Automatically ignoring own bundle identifier: \(ownBundleId)")
        }

        for url in candidateURLs {
            if fileManager.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(FileContents.self, from: data) {
                let configured = Set(decoded.ignoredBundleIdentifiers ?? [])
                let merged = configured.union(finalIgnoredBundles)
                Logger.debug("Loaded configuration from \(url.path) with ignored bundles: \(Array(merged))")
                return Configuration(ignoredBundleIdentifiers: merged)
            }
        }

        Logger.debug("No configuration file found; using default ignored bundles: \(Array(finalIgnoredBundles))")
        return Configuration(ignoredBundleIdentifiers: finalIgnoredBundles)
    }

    private static func configurationFileCandidates(fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(executableURL.appendingPathComponent("config.json"))

        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(workingDirectory.appendingPathComponent("config.json"))

        let applicationSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zonogy/config.json")
        candidates.append(applicationSupport)

        let homeConfig = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".zonogy/config.json")
        candidates.append(homeConfig)

        return candidates
    }
}
