/// A whole-seconds duration set in Preferences, kept within a range and persisted in UserDefaults.

import Foundation

struct SecondsPreference {
    /// How long Zonogy treats a change as temporary: the settle delay.
    static let settleDelay = SecondsPreference(
        key: UserDefaultsKeys.settleDelaySeconds, range: 1...60, defaultSeconds: 2
    )
    /// How long CmdTab's initial selection skips a window the user just minimized.
    static let cmdTabJustMinimizedSkip = SecondsPreference(
        key: UserDefaultsKeys.cmdTabJustMinimizedSkipSeconds, range: 1...60, defaultSeconds: 3
    )

    let key: String
    let range: ClosedRange<Int>
    let defaultSeconds: Int

    func loadSeconds() -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultSeconds
        }
        return normalizedSeconds(UserDefaults.standard.integer(forKey: key))
    }

    /// The duration as its uses measure it.
    func loadDuration() -> TimeInterval {
        TimeInterval(loadSeconds())
    }

    func saveSeconds(_ seconds: Int) {
        UserDefaults.standard.set(normalizedSeconds(seconds), forKey: key)
    }

    func normalizedSeconds(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
