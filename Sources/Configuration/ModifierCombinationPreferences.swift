/// Model and persistence for the configurable held-modifier combinations.
///
/// Two Zonogy gesture families are activated by holding a set of modifier keys, each configurable
/// in Preferences ▸ Shortcuts and defaulting to Control-Command: the mouse gestures (zone targeting
/// via click, drag promotion, and external-drag interception) and keyboard zone navigation.

import AppKit
import Carbon
import Foundation

/// A set of modifier keys that activates one of Zonogy's held-modifier gestures.
struct ModifierCombination: OptionSet, Codable, Equatable {
    let rawValue: Int

    static let control = ModifierCombination(rawValue: 1 << 0)
    static let option = ModifierCombination(rawValue: 1 << 1)
    static let shift = ModifierCombination(rawValue: 1 << 2)
    static let command = ModifierCombination(rawValue: 1 << 3)

    /// Display/iteration order, matching `KeyboardShortcut.displayString` (⌃⌥⇧⌘).
    static let displayOrder: [(modifier: ModifierCombination, symbol: String, name: String)] = [
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.shift, "⇧", "Shift"),
        (.command, "⌘", "Command"),
    ]

    /// A valid combination must include at least this many modifiers, so a stray click or key press
    /// (or a single modifier that shadows a system gesture like Control-click or Option-arrow) can
    /// never trigger a gesture.
    static let minimumCount = 2

    /// Factory default: Control-Command.
    static let defaultModifiers: ModifierCombination = [.control, .command]

    /// Number of recognized modifiers in the set.
    var count: Int {
        Self.displayOrder.reduce(0) { $0 + (contains($1.modifier) ? 1 : 0) }
    }

    var isValid: Bool { count >= Self.minimumCount }

    /// Equivalent `CGEventFlags`, for matching against `CGEventTap` events.
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    /// Equivalent `NSEvent.ModifierFlags`, for matching against `NSEvent.modifierFlags`.
    var nsEventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    /// Equivalent Carbon modifier flags, for comparing against `KeyboardShortcut.modifiers`.
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    /// Human-readable glyphs, e.g. "⌃⌘".
    var displayString: String {
        Self.displayOrder.compactMap { contains($0.modifier) ? $0.symbol : nil }.joined()
    }
}

/// Loads, caches, and persists one user-chosen modifier combination. Read live on the hot paths
/// (each click/drag or key chord consults `modifiers`), so changes apply immediately with no
/// re-registration. One instance per gesture family.
final class ModifierCombinationPreferences {
    /// The modifiers held while clicking or dragging to activate Zonogy's mouse gestures.
    static let mouseGestures = ModifierCombinationPreferences(
        defaultsKey: UserDefaultsKeys.mouseGestureModifiers, label: "mouse-gesture")

    /// The modifiers held during the keyboard zone-navigation gesture.
    static let zoneNavigation = ModifierCombinationPreferences(
        defaultsKey: UserDefaultsKeys.zoneNavigationModifiers, label: "zone-navigation")

    private let defaultsKey: String
    private let label: String
    private(set) var modifiers: ModifierCombination

    private init(defaultsKey: String, label: String) {
        self.defaultsKey = defaultsKey
        self.label = label
        self.modifiers = Self.load(key: defaultsKey)
    }

    /// Persist a new combination. Invalid combinations (fewer than `minimumCount`) are ignored so
    /// callers can pass UI state freely; the editors also gate their confirm buttons on validity.
    func update(_ newModifiers: ModifierCombination) {
        guard newModifiers.isValid else {
            Logger.debug("Ignoring invalid \(label) modifiers \(newModifiers.displayString) (need ≥\(ModifierCombination.minimumCount))")
            return
        }
        modifiers = newModifiers
        UserDefaults.standard.set(newModifiers.rawValue, forKey: defaultsKey)
        Logger.debug("Saved \(label) modifiers \(newModifiers.displayString)")
    }

    static func load(key: String) -> ModifierCombination {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else {
            return .defaultModifiers
        }
        let stored = ModifierCombination(rawValue: defaults.integer(forKey: key))
        // Fall back if a persisted value was somehow left invalid (e.g. a hand-edited default).
        return stored.isValid ? stored : .defaultModifiers
    }
}
