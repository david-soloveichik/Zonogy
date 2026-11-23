import Foundation

/// Guardrail tests for the whole-seconds preferences (default and clamping), run against each one.
enum SecondsPreferenceTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("SecondsPreferenceTests: \(message)")
                allPassed = false
            }
        }

        let defaults = UserDefaults.standard
        for preference in [SecondsPreference.settleDelay, .cmdTabJustMinimizedSkip] {
            let key = preference.key
            let range = preference.range
            let previousValue = defaults.object(forKey: key)
            defer {
                if let previousValue {
                    defaults.set(previousValue, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }

            defaults.removeObject(forKey: key)
            assert(preference.loadSeconds() == preference.defaultSeconds, "\(key) should default when unset")
            assert(range.contains(preference.defaultSeconds), "\(key) default should lie in its range")

            assert(
                preference.normalizedSeconds(range.lowerBound - 1) == range.lowerBound,
                "\(key) below its range should clamp to the minimum"
            )
            assert(
                preference.normalizedSeconds(range.upperBound + 1) == range.upperBound,
                "\(key) above its range should clamp to the maximum"
            )
            let middle = (range.lowerBound + range.upperBound) / 2
            assert(preference.normalizedSeconds(middle) == middle, "in-range \(key) should be preserved")

            preference.saveSeconds(range.upperBound + 1)
            assert(
                preference.loadSeconds() == range.upperBound,
                "saved \(key) should be normalized on read-back"
            )
        }

        if allPassed {
            print("SecondsPreferenceTests: all tests passed")
        }
        return allPassed
    }
}
