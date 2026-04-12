import Foundation

/// Lightweight runtime assertions for Preferences > Exceptions row composition and persistence.
enum ExceptionsPreferencesEntryTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ExceptionsPreferencesEntryTests: \(message)")
                allPassed = false
            }
        }

        do {
            let entries = ExceptionsPreferencesEntry.buildEntries(
                rules: [
                    ApplicationExceptionRule(bundleIdentifier: "com.example.rule", hasMainWindow: true)
                ],
                ignoredBundleIdentifiers: ["com.example.ignored", "com.example.rule"]
            )

            assert(entries.count == 2, "should include existing rules plus ignored-only apps")
            assert(entries[0].bundleIdentifier == "com.example.ignored", "entries should be sorted by bundle identifier for display")
            assert(entries[0].persistedRule == nil, "ignored-only entry should not invent an empty persisted rule")
            assert(entries[1].bundleIdentifier == "com.example.rule", "rule-backed entry should still be present after sorting")
            assert(entries[1].isIgnored == true, "rule-backed entry should reflect ignored state")
        }

        do {
            let entries = ExceptionsPreferencesEntry.buildEntries(
                rules: [
                    ApplicationExceptionRule(bundleIdentifier: "com.example.zed"),
                    ApplicationExceptionRule(bundleIdentifier: "com.example.alpha")
                ],
                ignoredBundleIdentifiers: ["com.example.middle"]
            )

            assert(
                entries.map(\.bundleIdentifier) == ["com.example.alpha", "com.example.middle", "com.example.zed"],
                "loaded entries should interleave rule-backed and ignored-only bundles in one alphabetical list"
            )
        }

        do {
            let entries = [
                ExceptionsPreferencesEntry(
                    rule: ApplicationExceptionRule(bundleIdentifier: "com.example.empty"),
                    isIgnored: false,
                    persistsRuleWithoutMeaningfulSettings: true
                ),
                ExceptionsPreferencesEntry(
                    rule: ApplicationExceptionRule(bundleIdentifier: "com.example.ignored"),
                    isIgnored: true,
                    persistsRuleWithoutMeaningfulSettings: false
                ),
                ExceptionsPreferencesEntry(
                    rule: ApplicationExceptionRule(
                        bundleIdentifier: "com.example.both",
                        ignoreHeightRequirement: true
                    ),
                    isIgnored: true,
                    persistsRuleWithoutMeaningfulSettings: false
                ),
            ]

            let persisted = ExceptionsPreferencesEntry.splitForPersistence(entries)
            assert(
                persisted.ignoredBundleIdentifiers == ["com.example.ignored", "com.example.both"],
                "ignored bundle identifiers should round-trip in entry order"
            )
            assert(
                persisted.rules.map(\.bundleIdentifier) == ["com.example.empty", "com.example.both"],
                "persistence should keep existing empty rules but avoid creating ignored-only placeholder rules"
            )
        }

        do {
            let summary = ExceptionsPreferencesEntry(
                rule: ApplicationExceptionRule(
                    bundleIdentifier: "com.example.summary",
                    hasMainWindow: true,
                    excludedWindowTitles: ["Preferences"]
                ),
                isIgnored: true,
                persistsRuleWithoutMeaningfulSettings: false
            ).summary

            assert(summary == "ignored, preferMain, excl:1", "summary should surface ignored state first")
        }

        if allPassed {
            print("ExceptionsPreferencesEntryTests: all tests passed")
        }
        return allPassed
    }
}
