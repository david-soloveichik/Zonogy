import AppKit
import Foundation

/// Guardrail tests for the mouse-gesture modifier model and its persistence/validation.
enum MouseGestureModifierPreferencesTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("MouseGestureModifierPreferencesTests: \(message)")
                allPassed = false
            }
        }

        // MARK: - Model: validity threshold (require ≥ 2)

        assert(!(MouseGestureModifiers([]).isValid), "empty set should be invalid")
        assert(!(MouseGestureModifiers.command.isValid), "a single modifier should be invalid")
        assert(MouseGestureModifiers([.control, .command]).isValid, "two modifiers should be valid")
        assert(MouseGestureModifiers([.control, .option, .shift, .command]).isValid, "all four should be valid")
        assert(MouseGestureModifiers([.control, .command]).count == 2, "count should tally recognized modifiers")

        // MARK: - Model: default

        assert(MouseGestureModifiers.defaultModifiers == [.control, .command], "default should be Control-Command")
        assert(MouseGestureModifiers.defaultModifiers.isValid, "default should be valid")

        // MARK: - Model: flag conversions

        let combo: MouseGestureModifiers = [.control, .command]
        assert(combo.cgEventFlags == [.maskControl, .maskCommand], "cgEventFlags should map control+command")
        assert(combo.nsEventFlags == [.control, .command], "nsEventFlags should map control+command")
        assert(MouseGestureModifiers.option.cgEventFlags == .maskAlternate, "option should map to maskAlternate")
        assert(MouseGestureModifiers.option.nsEventFlags == .option, "option should map to NSEvent .option")

        // MARK: - Model: display string order (⌃⌥⇧⌘)

        assert(combo.displayString == "⌃⌘", "display should be ⌃⌘ for control+command")
        assert(
            MouseGestureModifiers([.command, .shift, .option, .control]).displayString == "⌃⌥⇧⌘",
            "display order should be control, option, shift, command"
        )

        // MARK: - Persistence: default, round-trip, and invalid fallback

        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.mouseGestureModifiers
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        assert(
            MouseGestureModifierPreferences.load() == .defaultModifiers,
            "load should return the default when unset"
        )

        let saved: MouseGestureModifiers = [.option, .shift]
        defaults.set(saved.rawValue, forKey: key)
        assert(
            MouseGestureModifierPreferences.load() == saved,
            "a valid saved combination should round-trip"
        )

        defaults.set(MouseGestureModifiers.command.rawValue, forKey: key)
        assert(
            MouseGestureModifierPreferences.load() == .defaultModifiers,
            "an invalid persisted combination should fall back to the default"
        )

        // MARK: - update() ignores invalid combinations

        MouseGestureModifierPreferences.shared.update([.option, .shift])
        assert(
            MouseGestureModifierPreferences.shared.modifiers == [.option, .shift],
            "update should accept a valid combination"
        )
        MouseGestureModifierPreferences.shared.update(.command)
        assert(
            MouseGestureModifierPreferences.shared.modifiers == [.option, .shift],
            "update should ignore an invalid (single-modifier) combination"
        )

        if allPassed {
            print("MouseGestureModifierPreferencesTests: all tests passed")
        }
        return allPassed
    }
}
