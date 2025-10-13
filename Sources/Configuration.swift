import Foundation

struct Configuration: Decodable {
    private struct FileContents: Decodable {
        let ignoredBundleIdentifiers: [String]?
    }

    private static let defaultIgnoredBundles: Set<String> = [
        "com.microsoft.VSCode"
    ]

    let ignoredBundleIdentifiers: Set<String>

    static func load(fileManager: FileManager = .default) -> Configuration {
        let candidateURLs = configurationFileCandidates(fileManager: fileManager)

        for url in candidateURLs {
            if fileManager.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(FileContents.self, from: data) {
                let configured = Set(decoded.ignoredBundleIdentifiers ?? [])
                let merged = configured.union(defaultIgnoredBundles)
                Logger.debug("Loaded configuration from \(url.path) with ignored bundles: \(Array(merged))")
                return Configuration(ignoredBundleIdentifiers: merged)
            }
        }

        Logger.debug("No configuration file found; using default ignored bundles: \(Array(defaultIgnoredBundles))")
        return Configuration(ignoredBundleIdentifiers: defaultIgnoredBundles)
    }

    private static func configurationFileCandidates(fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(executableURL.appendingPathComponent("config.json"))

        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(workingDirectory.appendingPathComponent("config.json"))

        let applicationSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LatticeTopology/config.json")
        candidates.append(applicationSupport)

        let homeConfig = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".latticetopology/config.json")
        candidates.append(homeConfig)

        return candidates
    }
}
