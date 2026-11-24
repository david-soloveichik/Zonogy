/// Pure model for Preferences > Exceptions rows, combining rule and ignore state.

import Foundation

struct ExceptionsPreferencesEntry {
    var rule: ApplicationExceptionRule
    var isIgnored: Bool

    var bundleIdentifier: String {
        rule.bundleIdentifier
    }

    init(rule: ApplicationExceptionRule, isIgnored: Bool = false) {
        self.rule = rule
        self.isIgnored = isIgnored
    }

    var summary: String {
        var parts: [String] = []

        if isIgnored { parts.append(ExceptionOption.ignoredShortName) }
        parts += ExceptionOption.all.filter { rule[keyPath: $0.setting] == true }.map(\.shortName)
        if let titles = rule.excludedWindowTitles, !titles.isEmpty {
            parts.append("\(ExceptionOption.excludedTitlesShortName):\(titles.count)")
        }

        return parts.isEmpty ? "(none)" : parts.joined(separator: ", ")
    }

    /// The rule config.json keeps for this entry. An ignored entry needs one only for the settings it
    /// has, as the ignored list records the entry itself. Any other entry keeps its rule even when
    /// empty: the entry still takes precedence over broader patterns.
    var persistedRule: ApplicationExceptionRule? {
        isIgnored && !rule.hasMeaningfulExceptionSettings ? nil : rule
    }

    static func sortedForDisplay(_ entries: [ExceptionsPreferencesEntry]) -> [ExceptionsPreferencesEntry] {
        entries.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    static func buildEntries(
        rules: [ApplicationExceptionRule],
        ignoredBundleIdentifiers: [String]
    ) -> [ExceptionsPreferencesEntry] {
        let ignoredSet = Set(ignoredBundleIdentifiers)
        var entries = rules.map {
            ExceptionsPreferencesEntry(rule: $0, isIgnored: ignoredSet.contains($0.bundleIdentifier))
        }

        let existingBundleIdentifiers = Set(rules.map(\.bundleIdentifier))
        for bundleIdentifier in ignoredBundleIdentifiers where !existingBundleIdentifiers.contains(bundleIdentifier) {
            entries.append(
                ExceptionsPreferencesEntry(rule: ApplicationExceptionRule(bundleIdentifier: bundleIdentifier), isIgnored: true)
            )
        }

        return sortedForDisplay(entries)
    }

    static func splitForPersistence(
        _ entries: [ExceptionsPreferencesEntry]
    ) -> (ignoredBundleIdentifiers: [String], rules: [ApplicationExceptionRule]) {
        let ignoredBundleIdentifiers = entries.compactMap { entry in
            entry.isIgnored ? entry.bundleIdentifier : nil
        }
        let rules = entries.compactMap(\.persistedRule)
        return (ignoredBundleIdentifiers, rules)
    }
}
