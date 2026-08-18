/// Model and persistence for the keys zone navigation listens for.
///
/// Zone navigation has two groups of navigation keys, each switchable in the Zone Navigation
/// editor: the arrow keys, which step the blue circle between zones, and the jump keys, which jump
/// — four to the cells of the current screen's zone grid, one to its floating zone, three to the
/// displays (A/S/D/F, G, J/K/L by default). Both groups are on by default; a group turned off
/// carries no selection meaning, even mid-gesture, so its chords reach applications (unless a key
/// doubles as a borrowed shortcut key). The jump keys are the user's to change, each key held
/// once; the arrows and Escape are fixed, and the in-gesture action keys (move, Launcher, add,
/// remove, minimize) are borrowed from their shortcuts. Keys are matched by physical position, so
/// alternative layouts get the same key shape.

import Carbon
import Foundation

/// The navigation-key groups zone navigation listens for.
struct ZoneNavigationKeyGroups: OptionSet, Equatable {
    let rawValue: Int

    /// The arrow keys: step the circle one zone in the pressed direction.
    static let arrows = ZoneNavigationKeyGroups(rawValue: 1 << 0)
    /// The jump keys: straight to a zone, the floating zone, or a display.
    static let jumps = ZoneNavigationKeyGroups(rawValue: 1 << 1)

    /// Every group; also the factory default.
    static let all: ZoneNavigationKeyGroups = [.arrows, .jumps]
}

/// Which keys zone navigation listens for: the enabled groups and the key of each jump.
struct ZoneNavigationKeys: Equatable {
    var groups: ZoneNavigationKeyGroups
    /// The key of each jump in `ZoneNavigationKey.jumps`.
    var jumpKeys: [ZoneNavigationKey: CGKeyCode]

    /// The factory settings: both groups, and A/S/D/F, G, J/K/L.
    static let `default` = ZoneNavigationKeys(
        groups: .all,
        jumpKeys: [
            .zone(.topLeft): CGKeyCode(kVK_ANSI_A),
            .zone(.topRight): CGKeyCode(kVK_ANSI_S),
            .zone(.bottomLeft): CGKeyCode(kVK_ANSI_D),
            .zone(.bottomRight): CGKeyCode(kVK_ANSI_F),
            .floatingZone: CGKeyCode(kVK_ANSI_G),
            .display(ordinal: 0): CGKeyCode(kVK_ANSI_J),
            .display(ordinal: 1): CGKeyCode(kVK_ANSI_K),
            .display(ordinal: 2): CGKeyCode(kVK_ANSI_L),
        ]
    )

    /// The arrow keys, which are not the user's to change.
    static let arrowKeys: [CGKeyCode: ZoneNavigationKey] = [
        CGKeyCode(kVK_UpArrow): .move(.up),
        CGKeyCode(kVK_DownArrow): .move(.down),
        CGKeyCode(kVK_LeftArrow): .move(.left),
        CGKeyCode(kVK_RightArrow): .move(.right),
    ]

    /// Why a key can't be a jump's key: it has no name to be shown by, it keeps a meaning of its
    /// own in the gesture (the arrows step, Escape cancels), or another jump holds it.
    enum Rejection: Equatable {
        case unnamed
        case arrow
        case escape
        case inUse
    }

    /// Why `keyCode` can't be `jump`'s key, or nil when it can. The one policy behind both the
    /// editor's refusals and the check on stored keys.
    func rejection(of keyCode: CGKeyCode, as jump: ZoneNavigationKey) -> Rejection? {
        if KeyboardShortcut.keyLabel(forKeyCode: UInt32(keyCode)) == nil { return .unnamed }
        if Self.arrowKeys[keyCode] != nil { return .arrow }
        if keyCode == CGKeyCode(kVK_Escape) { return .escape }
        if ZoneNavigationKey.jumps.contains(where: { $0 != jump && self[$0] == keyCode }) { return .inUse }
        return nil
    }

    /// The key of a jump (one of `ZoneNavigationKey.jumps`).
    subscript(_ jump: ZoneNavigationKey) -> CGKeyCode {
        get { jumpKeys[jump] ?? Self.default.jumpKeys[jump] ?? 0 }
        set { jumpKeys[jump] = newValue }
    }

    /// Every selection key the enabled groups contribute, by key code.
    var selectionKeys: [CGKeyCode: ZoneNavigationKey] {
        var keys: [CGKeyCode: ZoneNavigationKey] = [:]
        if groups.contains(.arrows) {
            keys.merge(Self.arrowKeys) { current, _ in current }
        }
        if groups.contains(.jumps) {
            for jump in ZoneNavigationKey.jumps {
                keys[self[jump]] = jump
            }
        }
        return keys
    }

    /// Whether every jump key is one the editor would accept.
    var hasValidJumpKeys: Bool {
        ZoneNavigationKey.jumps.allSatisfy { rejection(of: self[$0], as: $0) == nil }
    }
}

/// Loads, caches, and persists the user's chosen keys, with the selection keys they contribute
/// precomputed for the keyboard event-tap callback. Read live when a chord arrives, so changes
/// apply immediately with no re-registration.
final class ZoneNavigationKeyPreferences {
    static let shared = ZoneNavigationKeyPreferences()

    private(set) var keys: ZoneNavigationKeys
    private(set) var selectionKeys: [CGKeyCode: ZoneNavigationKey]

    private init() {
        keys = Self.load()
        selectionKeys = keys.selectionKeys
    }

    func update(_ newKeys: ZoneNavigationKeys) {
        keys = newKeys
        selectionKeys = newKeys.selectionKeys
        let defaults = UserDefaults.standard
        defaults.set(newKeys.groups.rawValue, forKey: UserDefaultsKeys.zoneNavigationKeyGroups)
        defaults.set(
            ZoneNavigationKey.jumps.map { Int(newKeys[$0]) },
            forKey: UserDefaultsKeys.zoneNavigationJumpKeys)
        Logger.debug("Saved zone-navigation keys: groups \(newKeys.groups.rawValue)")
    }

    /// The saved keys, or the defaults where nothing is saved. Jump keys that don't hold up (a
    /// hand-edited default) fall back to the defaults as a whole; the groups stand on their own.
    static func load() -> ZoneNavigationKeys {
        let defaults = UserDefaults.standard
        var keys = ZoneNavigationKeys.default
        if defaults.object(forKey: UserDefaultsKeys.zoneNavigationKeyGroups) != nil {
            // Drop any bits a hand-edited default may carry beyond the known groups.
            keys.groups = ZoneNavigationKeyGroups(rawValue: defaults.integer(forKey: UserDefaultsKeys.zoneNavigationKeyGroups))
                .intersection(.all)
        }
        // Key codes are read exactly: an out-of-range value is as invalid as a duplicate, and one
        // among the jump keys can't hide by dropping out of the list.
        if let storedJumpCodes = defaults.array(forKey: UserDefaultsKeys.zoneNavigationJumpKeys) as? [Int],
           storedJumpCodes.count == ZoneNavigationKey.jumps.count {
            let jumpCodes = storedJumpCodes.compactMap { CGKeyCode(exactly: $0) }
            var candidate = keys
            candidate.jumpKeys = Dictionary(uniqueKeysWithValues: zip(ZoneNavigationKey.jumps, jumpCodes))
            if jumpCodes.count == storedJumpCodes.count, candidate.hasValidJumpKeys {
                keys = candidate
            }
        }
        return keys
    }
}
