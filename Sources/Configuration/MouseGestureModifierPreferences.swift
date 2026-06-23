/// Model and persistence for the configurable mouse-gesture modifier combination.
///
/// Several Zonogy mouse gestures (zone targeting via click, drag promotion, and external-drag
/// interception) are activated by holding a set of modifier keys. That set — the **gesture
/// modifiers** — defaults to Control-Command and is configurable in Preferences ▸ Shortcuts.

import AppKit
import Foundation

/// The set of modifier keys that activate Zonogy's mouse gestures.
struct MouseGestureModifiers: OptionSet, Codable, Equatable {
    let rawValue: Int

    static let control = MouseGestureModifiers(rawValue: 1 << 0)
    static let option = MouseGestureModifiers(rawValue: 1 << 1)
    static let shift = MouseGestureModifiers(rawValue: 1 << 2)
    static let command = MouseGestureModifiers(rawValue: 1 << 3)

    /// Display/iteration order, matching `KeyboardShortcut.displayString` (⌃⌥⇧⌘).
    static let displayOrder: [(modifier: MouseGestureModifiers, symbol: String, name: String)] = [
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.shift, "⇧", "Shift"),
        (.command, "⌘", "Command"),
    ]

    /// A valid combination must include at least this many modifiers, so a stray click (or a single
    /// modifier that shadows a system gesture like Control-click) can never trigger a gesture.
    static let minimumCount = 2

    /// Factory default: Control-Command.
    static let defaultModifiers: MouseGestureModifiers = [.control, .command]

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

    /// Human-readable glyphs, e.g. "⌃⌘".
    var displayString: String {
        Self.displayOrder.compactMap { contains($0.modifier) ? $0.symbol : nil }.joined()
    }
}

/// Loads, caches, and persists the user's chosen gesture modifiers. Read live on the hot paths
/// (each click/drag consults `shared.modifiers`), so changes apply immediately with no re-registration.
final class MouseGestureModifierPreferences {
    static let shared = MouseGestureModifierPreferences()

    private(set) var modifiers: MouseGestureModifiers

    private init() {
        modifiers = Self.load()
    }

    /// Persist a new combination. Invalid combinations (fewer than `minimumCount`) are ignored so
    /// callers can pass UI state freely; the editor also gates its confirm button on validity.
    func update(_ newModifiers: MouseGestureModifiers) {
        guard newModifiers.isValid else {
            Logger.debug("Ignoring invalid gesture modifiers \(newModifiers.displayString) (need ≥\(MouseGestureModifiers.minimumCount))")
            return
        }
        modifiers = newModifiers
        UserDefaults.standard.set(newModifiers.rawValue, forKey: UserDefaultsKeys.mouseGestureModifiers)
        Logger.debug("Saved gesture modifiers \(newModifiers.displayString)")
    }

    static func load() -> MouseGestureModifiers {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: UserDefaultsKeys.mouseGestureModifiers) != nil else {
            return .defaultModifiers
        }
        let stored = MouseGestureModifiers(rawValue: defaults.integer(forKey: UserDefaultsKeys.mouseGestureModifiers))
        // Fall back if a persisted value was somehow left invalid (e.g. a hand-edited default).
        return stored.isValid ? stored : .defaultModifiers
    }
}
