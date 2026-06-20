/// The CmdTab active-window targeting mode and its UserDefaults persistence.

import Foundation

/// Which CmdTab shortcuts retarget to the zone holding the active window before opening.
/// Each mode is a superset of the previous one.
enum CmdTabActiveWindowTargetingMode: Int, CaseIterable {
    /// Neither shortcut retargets; CmdTab always opens on the standard target.
    case off = 0
    /// Only the current-app shortcut (Cmd-`) retargets; all-windows (Cmd-Tab) uses the standard target.
    case currentAppOnly = 1
    /// Both the all-windows (Cmd-Tab) and current-app (Cmd-`) shortcuts retarget.
    case allWindows = 2

    /// Whether active-window retargeting applies for a CmdTab session opened in the given mode.
    func appliesRetargeting(in mode: CmdTabMode) -> Bool {
        switch self {
        case .off: return false
        case .currentAppOnly: return mode == .currentAppOnly
        case .allWindows: return true
        }
    }
}

enum CmdTabBehaviorPreferencesStore {
    /// Retargeting is off by default.
    static let defaultTargetingMode: CmdTabActiveWindowTargetingMode = .off

    /// Returns the targeting mode, falling back to the default when unset or invalid.
    static func loadTargetingMode() -> CmdTabActiveWindowTargetingMode {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.cmdTabActiveWindowTargetingMode) != nil else {
            return defaultTargetingMode
        }
        let raw = UserDefaults.standard.integer(forKey: UserDefaultsKeys.cmdTabActiveWindowTargetingMode)
        return CmdTabActiveWindowTargetingMode(rawValue: raw) ?? defaultTargetingMode
    }

    static func saveTargetingMode(_ mode: CmdTabActiveWindowTargetingMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: UserDefaultsKeys.cmdTabActiveWindowTargetingMode)
    }
}
