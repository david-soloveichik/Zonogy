/// Model and persistence for the zone-navigation selection-key groups.
///
/// Zone navigation listens for two groups of selection keys, each switchable in the Zone
/// Navigation editor: the arrow keys, which step the blue circle between zones, and the letter
/// keys, which jump — A/S/D/F to a cell of the current screen's zone grid, G to its floating zone,
/// J/K/L to a display. Both are on by default; a group turned off carries no selection meaning,
/// even mid-gesture, so its chords reach applications (unless a key doubles as a borrowed shortcut
/// key). Letters are matched by physical key position, so alternative layouts get the same key
/// shape.

import Carbon
import Foundation

/// The selection-key groups zone navigation listens for.
struct ZoneNavigationKeyGroups: OptionSet, Equatable {
    let rawValue: Int

    /// The arrow keys: step the circle one zone in the pressed direction.
    static let arrows = ZoneNavigationKeyGroups(rawValue: 1 << 0)
    /// The letter keys: A/S/D/F, G, and J/K/L jump straight to a zone, the floating zone, or a
    /// display.
    static let letters = ZoneNavigationKeyGroups(rawValue: 1 << 1)

    /// Every group; also the factory default.
    static let all: ZoneNavigationKeyGroups = [.arrows, .letters]

    static let arrowKeys: [CGKeyCode: ZoneNavigationKey] = [
        CGKeyCode(kVK_UpArrow): .move(.up),
        CGKeyCode(kVK_DownArrow): .move(.down),
        CGKeyCode(kVK_LeftArrow): .move(.left),
        CGKeyCode(kVK_RightArrow): .move(.right),
    ]

    static let letterKeys: [CGKeyCode: ZoneNavigationKey] = [
        CGKeyCode(kVK_ANSI_A): .zone(.topLeft),
        CGKeyCode(kVK_ANSI_S): .zone(.topRight),
        CGKeyCode(kVK_ANSI_D): .zone(.bottomLeft),
        CGKeyCode(kVK_ANSI_F): .zone(.bottomRight),
        CGKeyCode(kVK_ANSI_G): .floatingZone,
        CGKeyCode(kVK_ANSI_J): .display(ordinal: 0),
        CGKeyCode(kVK_ANSI_K): .display(ordinal: 1),
        CGKeyCode(kVK_ANSI_L): .display(ordinal: 2),
    ]

    /// Every selection key the enabled groups contribute, by key code.
    var selectionKeys: [CGKeyCode: ZoneNavigationKey] {
        var keys: [CGKeyCode: ZoneNavigationKey] = [:]
        if contains(.arrows) {
            keys.merge(Self.arrowKeys) { current, _ in current }
        }
        if contains(.letters) {
            keys.merge(Self.letterKeys) { current, _ in current }
        }
        return keys
    }
}

/// Loads, caches, and persists the user's chosen groups, with the selection keys they contribute
/// precomputed for the keyboard event-tap callback. Read live when a chord arrives, so changes
/// apply immediately with no re-registration.
final class ZoneNavigationKeyPreferences {
    static let shared = ZoneNavigationKeyPreferences()

    private(set) var groups: ZoneNavigationKeyGroups
    private(set) var selectionKeys: [CGKeyCode: ZoneNavigationKey]

    private init() {
        groups = Self.load()
        selectionKeys = groups.selectionKeys
    }

    func update(_ newGroups: ZoneNavigationKeyGroups) {
        groups = newGroups
        selectionKeys = newGroups.selectionKeys
        UserDefaults.standard.set(newGroups.rawValue, forKey: UserDefaultsKeys.zoneNavigationKeyGroups)
        Logger.debug("Saved zone-navigation key groups \(newGroups.rawValue)")
    }

    static func load() -> ZoneNavigationKeyGroups {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: UserDefaultsKeys.zoneNavigationKeyGroups) != nil else {
            return .all
        }
        // Drop any bits a hand-edited default may carry beyond the known groups.
        return ZoneNavigationKeyGroups(rawValue: defaults.integer(forKey: UserDefaultsKeys.zoneNavigationKeyGroups))
            .intersection(.all)
    }
}
