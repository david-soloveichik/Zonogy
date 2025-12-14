/// Persists and scores launch history (frecency + query preferences) to rank launch items.

import Foundation

final class LaunchItemUsageStore {
    struct UsageEntry: Codable {
        var count: Int
        var lastUsedAt: Date
    }

    struct PersistedState: Codable {
        var global: [String: UsageEntry]
        var perQuery: [String: [String: UsageEntry]]

        static let empty = PersistedState(global: [:], perQuery: [:])
    }

    private enum Constants {
        static let maxQueryKeys: Int = 600
        static let maxItemsPerQuery: Int = 40
        static let maxGlobalItems: Int = 6000
        static let maxPrefixLength: Int = 32

        static let queryBoostWeight: Double = 3.0
        static let recencyTauSeconds: TimeInterval = 60 * 60 * 24 * 10
    }

    private let fileURL: URL
    private var state: PersistedState
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        let url = Self.historyFileURL()
        self.fileURL = url
        self.state = Self.loadState(from: url)
    }

    func combinedScore(itemURL: URL, query: String) -> Double {
        combinedScore(itemURL: itemURL, query: query, now: now())
    }

    func combinedScore(itemURL: URL, query: String, now: Date) -> Double {
        let itemKey = Self.normalizedItemKey(for: itemURL)
        let queryKey = Self.normalizedQueryKey(query)
        return globalScore(itemKey: itemKey, now: now) + Constants.queryBoostWeight * queryScore(itemKey: itemKey, queryKey: queryKey, now: now)
    }

    func recordLaunch(query: String, itemURL: URL, recordQueryPreference: Bool) {
        let itemKey = Self.normalizedItemKey(for: itemURL)
        let now = now()

        state.global[itemKey] = updatedEntry(from: state.global[itemKey], now: now)

        let queryKey = Self.normalizedQueryKey(query)
        if recordQueryPreference, !queryKey.isEmpty {
            recordQueryPreferenceForKey(queryKey: queryKey, itemKey: itemKey, now: now)
        }

        pruneIfNeeded(now: now)
        persistAsync()
    }

    private func recordQueryPreferenceForKey(queryKey: String, itemKey: String, now: Date) {
        var perItem = state.perQuery[queryKey] ?? [:]
        perItem[itemKey] = updatedEntry(from: perItem[itemKey], now: now)
        state.perQuery[queryKey] = perItem

        guard Constants.maxPrefixLength > 0 else { return }
        for prefixKey in prefixKeys(for: queryKey) {
            var perPrefix = state.perQuery[prefixKey] ?? [:]
            perPrefix[itemKey] = updatedEntry(from: perPrefix[itemKey], now: now)
            state.perQuery[prefixKey] = perPrefix
        }
    }

    private func updatedEntry(from existing: UsageEntry?, now: Date) -> UsageEntry {
        UsageEntry(count: (existing?.count ?? 0) + 1, lastUsedAt: now)
    }

    private func globalScore(itemKey: String, now: Date) -> Double {
        guard let entry = state.global[itemKey] else { return 0 }
        return score(for: entry, now: now)
    }

    private func queryScore(itemKey: String, queryKey: String, now: Date) -> Double {
        guard !queryKey.isEmpty else { return 0 }
        guard let entry = state.perQuery[queryKey]?[itemKey] else { return 0 }
        return score(for: entry, now: now)
    }

    private func score(for entry: UsageEntry, now: Date) -> Double {
        let ageSeconds = max(0, now.timeIntervalSince(entry.lastUsedAt))
        let recency = exp(-ageSeconds / Constants.recencyTauSeconds)
        return log1p(Double(entry.count)) + recency
    }

    private func pruneIfNeeded(now: Date) {
        if state.global.count > Constants.maxGlobalItems {
            state.global = Self.pruneDictionary(state.global, maxCount: Constants.maxGlobalItems)
        }

        if state.perQuery.count > Constants.maxQueryKeys {
            state.perQuery = Self.pruneDictionary(state.perQuery, maxCount: Constants.maxQueryKeys) { _, perItem in
                perItem.values.map(\.lastUsedAt).max() ?? .distantPast
            }
        }

        if !state.perQuery.isEmpty {
            for (queryKey, perItem) in state.perQuery {
                if perItem.count > Constants.maxItemsPerQuery {
                    state.perQuery[queryKey] = Self.pruneDictionary(perItem, maxCount: Constants.maxItemsPerQuery)
                }
            }
        }
    }

    private static func pruneDictionary<Value>(
        _ dictionary: [String: Value],
        maxCount: Int,
        lastUsedAt: (_ key: String, _ value: Value) -> Date
    ) -> [String: Value] {
        guard dictionary.count > maxCount else { return dictionary }

        let sorted = dictionary.sorted { lhs, rhs in
            let leftDate = lastUsedAt(lhs.key, lhs.value)
            let rightDate = lastUsedAt(rhs.key, rhs.value)
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.key < rhs.key
        }

        var pruned: [String: Value] = [:]
        pruned.reserveCapacity(maxCount)
        for (key, value) in sorted.prefix(maxCount) {
            pruned[key] = value
        }
        return pruned
    }

    private static func pruneDictionary(_ dictionary: [String: UsageEntry], maxCount: Int) -> [String: UsageEntry] {
        pruneDictionary(dictionary, maxCount: maxCount) { _, value in value.lastUsedAt }
    }

    private func persistAsync() {
        let url = fileURL
        let snapshot = state

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }

        Task.detached(priority: .utility) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private static func loadState(from url: URL) -> PersistedState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PersistedState.self, from: data)) ?? .empty
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

    private static func normalizedItemKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizedQueryKey(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func prefixKeys(for queryKey: String) -> [String] {
        guard queryKey.count > 1 else { return [] }

        let maxLength = min(Constants.maxPrefixLength, queryKey.count - 1)
        var prefixes: [String] = []
        prefixes.reserveCapacity(maxLength)

        var endIndex = queryKey.startIndex
        for _ in 0..<maxLength {
            endIndex = queryKey.index(after: endIndex)
            prefixes.append(String(queryKey[..<endIndex]))
        }

        return prefixes
    }
}
