/// Persists the user-facing zone layout style preference.

import Foundation

enum ZoneLayoutStylePreferencesStore {
    private static let defaultStyle: ZoneLayoutStyle = .rightBar

    static func loadStyle() -> ZoneLayoutStyle {
        guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.zoneLayoutStyle),
              let style = ZoneLayoutStyle(rawValue: raw) else {
            return defaultStyle
        }
        return style
    }

    static func saveStyle(_ style: ZoneLayoutStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: UserDefaultsKeys.zoneLayoutStyle)
    }
}
