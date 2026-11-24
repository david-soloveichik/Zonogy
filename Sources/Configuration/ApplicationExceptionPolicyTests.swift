import Foundation

/// Lightweight runtime assertions for ApplicationExceptionPolicy lookup, bundle identifier patterns included.
enum ApplicationExceptionPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ApplicationExceptionPolicyTests: \(message)")
                allPassed = false
            }
        }

        do {
            let bundleA = "com.example.a"
            let bundleB = "com.example.b"
            let bundleC = "com.example.c"

            let bundleD = "com.example.d"
            let bundleE = "com.example.e"
            let bundleF = "com.example.f"
            let bundleG = "com.example.g"

            let rules: [ApplicationExceptionRule] = [
                ApplicationExceptionRule(bundleIdentifier: bundleA, ignoreActivationPolicy: true),
                ApplicationExceptionRule(bundleIdentifier: bundleA, ignoreActivationPolicy: false), // last wins
                ApplicationExceptionRule(bundleIdentifier: bundleB, disallowEmptyTitleWindows: true, excludedWindowTitles: ["Hidden"]),
                ApplicationExceptionRule(bundleIdentifier: bundleC, treatAXUnknownFullWidthAsFullScreen: true),
                ApplicationExceptionRule(bundleIdentifier: bundleD, requireActiveZoomButton: true),
                ApplicationExceptionRule(bundleIdentifier: bundleE, disableMouseGestures: true),
                ApplicationExceptionRule(bundleIdentifier: bundleF, doNotResizeWidth: true),
                ApplicationExceptionRule(bundleIdentifier: bundleG, manageNonStandardWindows: true),
            ]

            let policy = ApplicationExceptionPolicy(rules: rules)

            assert(policy.ignoresActivationPolicy(forBundleIdentifier: bundleA) == false, "last rule for a bundle should win")
            assert(policy.ignoresActivationPolicy(forBundleIdentifier: "com.unknown") == false, "unknown bundle should use defaults")
            assert(policy.disallowsEmptyTitleWindows(forBundleIdentifier: bundleB) == true, "should honor per-bundle empty title preference")
            assert(policy.excludedWindowTitles(forBundleIdentifier: bundleB) == ["Hidden"], "should return excluded titles list")
            assert(policy.excludedWindowTitles(forBundleIdentifier: "com.unknown") == [], "unknown bundle should return empty excluded titles")
            assert(policy.treatsAXUnknownFullWidthAsFullScreen(forBundleIdentifier: bundleC) == true, "should honor per-bundle AXUnknown full-screen preference")
            assert(policy.treatsAXUnknownFullWidthAsFullScreen(forBundleIdentifier: "com.unknown") == false, "unknown bundle should default AXUnknown full-screen preference to false")
            assert(policy.requiresActiveZoomButton(forBundleIdentifier: bundleD) == true, "should honor per-bundle requireActiveZoomButton preference")
            assert(policy.requiresActiveZoomButton(forBundleIdentifier: "com.unknown") == false, "unknown bundle should default requireActiveZoomButton to false")
            assert(policy.disablesMouseGestures(forBundleIdentifier: bundleE) == true, "should honor per-bundle mouse-gesture preference")
            assert(policy.disablesMouseGestures(forBundleIdentifier: "com.unknown") == false, "unknown bundle should default mouse-gesture preference to false")
            assert(policy.doesNotResizeWidth(forBundleIdentifier: bundleF) == true, "should honor per-bundle width-resize exception")
            assert(policy.doesNotResizeWidth(forBundleIdentifier: "com.unknown") == false, "unknown bundle should default width-resize exception to false")
            assert(policy.managesNonStandardWindows(forBundleIdentifier: bundleG) == true, "should honor per-bundle non-standard window exception")
            assert(policy.managesNonStandardWindows(forBundleIdentifier: "com.unknown") == false, "unknown bundle should default non-standard window exception to false")
        }

        do {
            // Patterns: each app follows only its most specific entry, whether it is ignored included
            let policy = ApplicationExceptionPolicy(
                rules: [
                    ApplicationExceptionRule(bundleIdentifier: "com.adobe.*", hasMainWindow: true),
                    ApplicationExceptionRule(bundleIdentifier: "com.adobe.PremierePro*", manageNonStandardWindows: true),
                    ApplicationExceptionRule(bundleIdentifier: "com.adobe.PremierePro.26", doNotResizeWidth: true),
                    ApplicationExceptionRule(bundleIdentifier: "com.adobe.illustrator", ignoreZoomButtonRequirement: true),
                    ApplicationExceptionRule(bundleIdentifier: "com.ignored.kept", ignoreHeightRequirement: true),
                ],
                ignoredBundleIdentifiers: ["com.ignored.*", "com.adobe.illustrator"]
            )

            assert(policy.managesNonStandardWindows(forBundleIdentifier: "com.adobe.PremierePro.27"), "a pattern should match bundle identifiers that start with its prefix")
            assert(!policy.hasMainWindow(forBundleIdentifier: "com.adobe.PremierePro.27"), "the longer pattern should win, without merging the shorter one's settings")
            assert(policy.hasMainWindow(forBundleIdentifier: "com.adobe.Photoshop"), "the shorter pattern should still cover apps the longer one doesn't")
            assert(!policy.hasMainWindow(forBundleIdentifier: "com.adobe"), "a pattern should not match a bundle identifier shorter than its prefix")
            assert(
                policy.doesNotResizeWidth(forBundleIdentifier: "com.adobe.PremierePro.26")
                    && !policy.managesNonStandardWindows(forBundleIdentifier: "com.adobe.PremierePro.26"),
                "an exact entry should win over patterns"
            )
            assert(policy.ignoresApplication(forBundleIdentifier: "com.ignored.other"), "an ignored pattern should ignore the apps it matches")
            assert(!policy.ignoresApplication(forBundleIdentifier: "com.ignored.kept"), "a more specific entry should exempt an app from an ignored pattern")
            assert(policy.ignoresHeightRequirement(forBundleIdentifier: "com.ignored.kept"), "the exempting entry's own settings should apply")
            assert(policy.ignoresApplication(forBundleIdentifier: "com.adobe.illustrator"), "an exact entry can be both ignored and carry a rule")
            assert(!policy.ignoresApplication(forBundleIdentifier: "com.adobe.Photoshop"), "a rule-only pattern should not ignore apps")
        }

        if allPassed {
            print("ApplicationExceptionPolicyTests: all tests passed")
        }
        return allPassed
    }
}
