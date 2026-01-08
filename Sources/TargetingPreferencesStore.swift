/// Persists user-facing targeting mode preferences using UserDefaults.

import Foundation

enum TargetingPreferencesStore {
    private static let defaultMode: TargetingMode = .independentOfFocus

    static func loadMode() -> TargetingMode {
        guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.targetingMode),
              let mode = TargetingMode(rawValue: raw) else {
            return defaultMode
        }
        return mode
    }

    static func saveMode(_ mode: TargetingMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: UserDefaultsKeys.targetingMode)
    }
}
