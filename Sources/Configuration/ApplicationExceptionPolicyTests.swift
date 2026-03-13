import Foundation

/// Lightweight runtime assertions for ApplicationExceptionPolicy lookup and merge semantics.
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
            let base = ApplicationExceptionRule(
                bundleIdentifier: "com.example.app",
                ignoreActivationPolicy: true,
                ignoreZoomButtonRequirement: nil,
                ignoreHeightRequirement: true,
                disallowEmptyTitleWindows: nil,
                hasMainWindow: true,
                snapToZoneOnSelfResize: nil,
                disableControlCommandMouseGestures: true,
                treatAXUnknownFullWidthAsFullScreen: true,
                requireActiveZoomButton: true,
                excludedWindowTitles: ["Foo"]
            )
            let override = ApplicationExceptionRule(
                bundleIdentifier: "com.example.app",
                ignoreActivationPolicy: nil,
                ignoreZoomButtonRequirement: false,
                ignoreHeightRequirement: nil,
                disallowEmptyTitleWindows: true,
                hasMainWindow: nil,
                snapToZoneOnSelfResize: true,
                disableControlCommandMouseGestures: nil,
                treatAXUnknownFullWidthAsFullScreen: false,
                requireActiveZoomButton: nil,
                excludedWindowTitles: ["Bar"]
            )
            let merged = base.merged(with: override)

            assert(merged.bundleIdentifier == "com.example.app", "merged rule should preserve bundle identifier")
            assert(merged.ignoreActivationPolicy == true, "nil override should keep base value")
            assert(merged.ignoreZoomButtonRequirement == false, "non-nil override should replace base value")
            assert(merged.ignoreHeightRequirement == true, "nil override should keep base value")
            assert(merged.disallowEmptyTitleWindows == true, "non-nil override should replace base value")
            assert(merged.hasMainWindow == true, "nil override should keep base value")
            assert(merged.snapToZoneOnSelfResize == true, "non-nil override should replace base value")
            assert(merged.disableControlCommandMouseGestures == true, "nil override should keep base Control-Command gesture value")
            assert(merged.treatAXUnknownFullWidthAsFullScreen == false, "non-nil override should replace base value")
            assert(merged.requireActiveZoomButton == true, "nil override should keep base value")
            assert(merged.excludedWindowTitles == ["Bar"], "non-nil override list should replace base list")
        }

        do {
            let bundleA = "com.example.a"
            let bundleB = "com.example.b"
            let bundleC = "com.example.c"

            let bundleD = "com.example.d"
            let bundleE = "com.example.e"

            let rules: [ApplicationExceptionRule] = [
                ApplicationExceptionRule(bundleIdentifier: bundleA, ignoreActivationPolicy: true),
                ApplicationExceptionRule(bundleIdentifier: bundleA, ignoreActivationPolicy: false), // last wins
                ApplicationExceptionRule(bundleIdentifier: bundleB, disallowEmptyTitleWindows: true, excludedWindowTitles: ["Hidden"]),
                ApplicationExceptionRule(bundleIdentifier: bundleC, treatAXUnknownFullWidthAsFullScreen: true),
                ApplicationExceptionRule(bundleIdentifier: bundleD, requireActiveZoomButton: true),
                ApplicationExceptionRule(bundleIdentifier: bundleE, disableControlCommandMouseGestures: true),
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
            assert(policy.disablesControlCommandMouseGestures(forBundleIdentifier: bundleE) == true, "should honor per-bundle Control-Command mouse gesture preference")
            assert(policy.disablesControlCommandMouseGestures(forBundleIdentifier: "com.unknown") == false, "unknown bundle should default Control-Command mouse gesture preference to false")
        }

        if allPassed {
            print("ApplicationExceptionPolicyTests: all tests passed")
        }
        return allPassed
    }
}
