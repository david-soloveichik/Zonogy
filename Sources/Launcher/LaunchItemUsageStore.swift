/// Persists launch history (per-query selections + app recency) to rank launch items.

import Foundation

final class LaunchItemUsageStore {
    /// Shared instance for use by both Launcher and Zonogy's window management
    static let shared = LaunchItemUsageStore()

    /// Per-query selection history: last 5 items selected for each query
    /// Key: normalized query string, Value: ordered list of item keys (most recent first)
    private var perQueryHistory: [String: [String]]

    /// Query recency: ordered list of query keys (most recently used first)
    /// Used to determine which queries to prune when we exceed the limit
    private var queryRecency: [String]

    /// Application recency: ordered list of bundle identifiers (most recent first)
    /// Updated whenever any app becomes active (via Launcher, Dock, Cmd-Tab, etc.)
    private var appRecency: [String]

    private enum Constants {
        /// Max selections to keep per query
        static let maxSelectionsPerQuery: Int = 5
        /// Max queries to track (prune oldest when exceeded)
        static let maxQueryKeys: Int = 1000
        /// Max apps in recency list
        static let maxRecencyApps: Int = 500
        /// Debounce interval for persistence (seconds)
        static let persistDebounceInterval: TimeInterval = 0.5
    }

    private let fileURL: URL

    /// Pending persistence task (for debouncing)
    private var pendingPersistTask: Task<Void, Never>?

    /// Serial queue for persistence to prevent out-of-order writes
    private let persistQueue = DispatchQueue(label: "com.zonogy.launcher-history-persist")

    private init() {
        let url = Self.historyFileURL()
        self.fileURL = url
        let loaded = Self.loadState(from: url)
        self.perQueryHistory = loaded.perQuery
        self.queryRecency = loaded.queryRecency
        self.appRecency = loaded.appRecency
    }

    // MARK: - Per-Query History

    /// Returns how many times this item appears in the last 5 selections for this query (0-5)
    func perQueryCount(itemKey: String, query: String) -> Int {
        let queryKey = Self.normalizedQueryKey(query)
        guard !queryKey.isEmpty else { return 0 }
        guard let history = perQueryHistory[queryKey] else { return 0 }
        return history.filter { $0 == itemKey }.count
    }

    /// Record that an item was selected for a query
    func recordSelection(query: String, itemURL: URL) {
        let queryKey = Self.normalizedQueryKey(query)
        guard !queryKey.isEmpty else { return }

        let itemKey = Self.normalizedItemKey(for: itemURL)
        var history = perQueryHistory[queryKey] ?? []

        // Add to front, cap at 5
        history.insert(itemKey, at: 0)
        if history.count > Constants.maxSelectionsPerQuery {
            history = Array(history.prefix(Constants.maxSelectionsPerQuery))
        }
        perQueryHistory[queryKey] = history

        // Update query recency (move to front)
        queryRecency.removeAll { $0 == queryKey }
        queryRecency.insert(queryKey, at: 0)

        pruneQueriesIfNeeded()
        schedulePersist()
    }

    // MARK: - Application Recency

    /// Returns the recency rank for an app (0 = most recent, higher = less recent)
    /// Apps not in the list return a high default value
    func recencyRank(bundleIdentifier: String) -> Int {
        if let index = appRecency.firstIndex(of: bundleIdentifier) {
            return index
        }
        return Int.max
    }

    /// Record that an app became active (moves to front of recency list)
    func recordAppActivation(bundleIdentifier: String) {
        // Remove if already present, then insert at front
        appRecency.removeAll { $0 == bundleIdentifier }
        appRecency.insert(bundleIdentifier, at: 0)

        // Cap the list
        if appRecency.count > Constants.maxRecencyApps {
            appRecency = Array(appRecency.prefix(Constants.maxRecencyApps))
        }

        schedulePersist()
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var perQuery: [String: [String]]
        var queryRecency: [String]
        var appRecency: [String]

        static let empty = PersistedState(perQuery: [:], queryRecency: [], appRecency: [])

        init(perQuery: [String: [String]], queryRecency: [String], appRecency: [String]) {
            self.perQuery = perQuery
            self.queryRecency = queryRecency
            self.appRecency = appRecency
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            perQuery = try container.decode([String: [String]].self, forKey: .perQuery)
            queryRecency = try container.decodeIfPresent([String].self, forKey: .queryRecency) ?? []
            appRecency = try container.decode([String].self, forKey: .appRecency)
        }
    }

    private func pruneQueriesIfNeeded() {
        guard perQueryHistory.count > Constants.maxQueryKeys else { return }

        // Remove oldest queries (from the end of queryRecency list)
        let keysToKeep = Set(queryRecency.prefix(Constants.maxQueryKeys))

        // Remove queries not in the keep set
        for key in perQueryHistory.keys where !keysToKeep.contains(key) {
            perQueryHistory.removeValue(forKey: key)
        }

        // Trim queryRecency to match
        if queryRecency.count > Constants.maxQueryKeys {
            queryRecency = Array(queryRecency.prefix(Constants.maxQueryKeys))
        }
    }

    /// Schedule a debounced persist - coalesces rapid updates
    private func schedulePersist() {
        pendingPersistTask?.cancel()
        pendingPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Constants.persistDebounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Actually perform the persistence (called after debounce)
    private func persistNow() {
        let snapshot = PersistedState(perQuery: perQueryHistory, queryRecency: queryRecency, appRecency: appRecency)
        let url = fileURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }

        // Use serial queue to ensure writes complete in order
        persistQueue.async {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private static func loadState(from url: URL) -> PersistedState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(PersistedState.self, from: data)) ?? .empty
    }

    private static func historyFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base.appending(path: "Zonogy", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appending(path: "launcher-history.json", directoryHint: .notDirectory)
    }

    static func normalizedItemKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizedQueryKey(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
