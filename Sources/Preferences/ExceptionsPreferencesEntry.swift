/// Pure model for Preferences > Exceptions rows, combining rule and ignore state.

import Foundation

struct ExceptionsPreferencesEntry {
    var rule: ApplicationExceptionRule
    var isIgnored: Bool
    private(set) var persistsRuleWithoutMeaningfulSettings: Bool

    var bundleIdentifier: String {
        rule.bundleIdentifier
    }

    init(
        rule: ApplicationExceptionRule,
        isIgnored: Bool = false,
        persistsRuleWithoutMeaningfulSettings: Bool = true
    ) {
        self.rule = rule
        self.isIgnored = isIgnored
        self.persistsRuleWithoutMeaningfulSettings = persistsRuleWithoutMeaningfulSettings
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

    var persistedRule: ApplicationExceptionRule? {
        if rule.hasMeaningfulExceptionSettings || persistsRuleWithoutMeaningfulSettings {
            return rule
        }
        return nil
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
            ExceptionsPreferencesEntry(
                rule: $0,
                isIgnored: ignoredSet.contains($0.bundleIdentifier),
                persistsRuleWithoutMeaningfulSettings: true
            )
        }

        let existingBundleIdentifiers = Set(rules.map(\.bundleIdentifier))
        for bundleIdentifier in ignoredBundleIdentifiers where !existingBundleIdentifiers.contains(bundleIdentifier) {
            entries.append(
                ExceptionsPreferencesEntry(
                    rule: ApplicationExceptionRule(bundleIdentifier: bundleIdentifier),
                    isIgnored: true,
                    persistsRuleWithoutMeaningfulSettings: false
                )
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
