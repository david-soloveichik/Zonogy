import Foundation

/// Guardrail tests for adding bundled defaults to config.json: each default exception rule arrives
/// once, never overrides the user's own rule for that app, and stays removed once the user removes it.
enum ExceptionsConfigurationStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ExceptionsConfigurationStoreTests: \(message)")
                allPassed = false
            }
        }

        typealias UserConfig = ExceptionsConfigurationStore.UserConfig
        let ruleA = ApplicationExceptionRule(bundleIdentifier: "com.example.a", hasMainWindow: true)
        let ruleB = ApplicationExceptionRule(bundleIdentifier: "com.example.b", doNotResizeWidth: true)
        let ruleC = ApplicationExceptionRule(bundleIdentifier: "com.example.c", treatAXUnknownFullWidthAsFullScreen: true)
        let allIds = ["com.example.a", "com.example.b", "com.example.c"]
        let defaults = UserConfig(
            ignoredBundleIdentifiers: ["com.example.ignored"],
            deriveBundleIdFromPathForProcesses: ["java"],
            bundleExceptions: [ruleA, ruleB, ruleC]
        )

        do {
            var config = UserConfig(ignoredBundleIdentifiers: defaults.ignoredBundleIdentifiers)
            _ = config.addMissingDefaults(from: defaults)
            assert(
                config == UserConfig(
                    ignoredBundleIdentifiers: ["com.example.ignored"],
                    deriveBundleIdFromPathForProcesses: ["java"],
                    bundleExceptions: [ruleA, ruleB, ruleC],
                    offeredDefaultExceptions: allIds
                ),
                "a new file should receive every default and record each rule as offered"
            )
        }

        do {
            // Written before rule C became a default; the user customized A and removed B.
            let customizedA = ApplicationExceptionRule(bundleIdentifier: "com.example.a", snapToZoneOnSelfResize: true)
            var config = UserConfig(
                deriveBundleIdFromPathForProcesses: [],
                bundleExceptions: [customizedA],
                offeredDefaultExceptions: ["com.example.a", "com.example.b"]
            )
            assert(config.addMissingDefaults(from: defaults), "a new default rule should change the config")
            assert(config.bundleExceptions == [customizedA, ruleC], "only the new default rule should be added")
            assert(config.offeredDefaultExceptions == allIds, "the new default rule should be recorded as offered")
            assert(config.deriveBundleIdFromPathForProcesses == [], "an existing process list should be kept even when empty")
            assert(!config.addMissingDefaults(from: defaults), "a second pass should change nothing")
        }

        do {
            // Written before offered rules were recorded: every missing default rule arrives, once.
            var config = UserConfig(bundleExceptions: [ruleA])
            assert(config.addMissingDefaults(from: defaults), "an unrecorded config should be updated")
            assert(config.bundleExceptions == [ruleA, ruleB, ruleC], "missing default rules should be added")
            assert(config.deriveBundleIdFromPathForProcesses == ["java"], "a missing process list should come from the defaults")
            config.bundleExceptions = [ruleA]
            assert(!config.addMissingDefaults(from: defaults), "default rules the user removed should stay removed")
        }

        if allPassed {
            print("ExceptionsConfigurationStoreTests: all tests passed")
        }
        return allPassed
    }
}
