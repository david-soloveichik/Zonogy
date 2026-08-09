/// Model and persistence for the zone-navigation selection-key preset.
///
/// The arrow keys always move the zone-navigation selection; the chosen keyset can add a letter
/// cluster (Vim's HJKL, gaming's WASD, or the right-hand IJKL) alongside them. Letters are matched
/// by physical key position, so alternative layouts get the familiar cluster shape.

import Carbon
import Foundation

/// The selection-key preset for keyboard zone navigation.
enum ZoneNavigationKeyset: String, CaseIterable, Codable {
    case arrows
    case hjkl
    case wasd
    case ijkl

    /// The always-active arrow cluster.
    static let arrowKeys: [CGKeyCode: ZoneNavigationDirection] = [
        CGKeyCode(kVK_UpArrow): .up,
        CGKeyCode(kVK_DownArrow): .down,
        CGKeyCode(kVK_LeftArrow): .left,
        CGKeyCode(kVK_RightArrow): .right,
    ]

    /// The preset's letter keys; empty for `.arrows`.
    var letterKeys: [CGKeyCode: ZoneNavigationDirection] {
        switch self {
        case .arrows:
            return [:]
        case .hjkl:
            return [
                CGKeyCode(kVK_ANSI_H): .left,
                CGKeyCode(kVK_ANSI_J): .down,
                CGKeyCode(kVK_ANSI_K): .up,
                CGKeyCode(kVK_ANSI_L): .right,
            ]
        case .wasd:
            return [
                CGKeyCode(kVK_ANSI_W): .up,
                CGKeyCode(kVK_ANSI_A): .left,
                CGKeyCode(kVK_ANSI_S): .down,
                CGKeyCode(kVK_ANSI_D): .right,
            ]
        case .ijkl:
            return [
                CGKeyCode(kVK_ANSI_I): .up,
                CGKeyCode(kVK_ANSI_J): .left,
                CGKeyCode(kVK_ANSI_K): .down,
                CGKeyCode(kVK_ANSI_L): .right,
            ]
        }
    }

    /// Every key that moves the selection under this preset: the arrows plus the preset's letters.
    /// Precomputed per preset — this is read in the keyboard event-tap callback.
    var directionKeys: [CGKeyCode: ZoneNavigationDirection] {
        Self.directionKeysByKeyset[self] ?? Self.arrowKeys
    }

    private static let directionKeysByKeyset: [ZoneNavigationKeyset: [CGKeyCode: ZoneNavigationDirection]] =
        Dictionary(uniqueKeysWithValues: allCases.map { keyset in
            (keyset, arrowKeys.merging(keyset.letterKeys) { arrow, _ in arrow })
        })

    /// Picker label in the editor sheet.
    var displayName: String {
        switch self {
        case .arrows: return "Arrow Keys"
        case .hjkl: return "HJKL"
        case .wasd: return "WASD"
        case .ijkl: return "IJKL"
        }
    }

    /// The letters as shown in the walkthrough (e.g. "H/J/K/L"); nil for `.arrows`.
    var lettersDisplayString: String? {
        switch self {
        case .arrows: return nil
        case .hjkl: return "H/J/K/L"
        case .wasd: return "W/A/S/D"
        case .ijkl: return "I/J/K/L"
        }
    }

    /// Factory default: arrow keys only.
    static let defaultKeyset: ZoneNavigationKeyset = .arrows
}

/// Loads, caches, and persists the user's chosen keyset. Read live when a chord engages, so changes
/// apply immediately with no re-registration.
final class ZoneNavigationKeysetPreferences {
    static let shared = ZoneNavigationKeysetPreferences()

    private(set) var keyset: ZoneNavigationKeyset

    private init() {
        keyset = Self.load()
    }

    func update(_ newKeyset: ZoneNavigationKeyset) {
        keyset = newKeyset
        UserDefaults.standard.set(newKeyset.rawValue, forKey: UserDefaultsKeys.zoneNavigationKeyset)
        Logger.debug("Saved zone-navigation keyset \(newKeyset.rawValue)")
    }

    static func load() -> ZoneNavigationKeyset {
        guard let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.zoneNavigationKeyset),
              let keyset = ZoneNavigationKeyset(rawValue: stored) else {
            return .defaultKeyset
        }
        return keyset
    }
}
