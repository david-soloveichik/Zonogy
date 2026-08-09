import AppKit
import Carbon
import Foundation

/// Guardrail tests for the held-modifier combination model and its persistence/validation.
enum ModifierCombinationPreferencesTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ModifierCombinationPreferencesTests: \(message)")
                allPassed = false
            }
        }

        // MARK: - Model: validity threshold (require ≥ 2)

        assert(!(ModifierCombination([]).isValid), "empty set should be invalid")
        assert(!(ModifierCombination.command.isValid), "a single modifier should be invalid")
        assert(ModifierCombination([.control, .command]).isValid, "two modifiers should be valid")
        assert(ModifierCombination([.control, .option, .shift, .command]).isValid, "all four should be valid")
        assert(ModifierCombination([.control, .command]).count == 2, "count should tally recognized modifiers")

        // MARK: - Model: default

        assert(ModifierCombination.defaultModifiers == [.control, .command], "default should be Control-Command")
        assert(ModifierCombination.defaultModifiers.isValid, "default should be valid")

        // MARK: - Model: flag conversions

        let combo: ModifierCombination = [.control, .command]
        assert(combo.cgEventFlags == [.maskControl, .maskCommand], "cgEventFlags should map control+command")
        assert(combo.nsEventFlags == [.control, .command], "nsEventFlags should map control+command")
        assert(combo.carbonModifiers == UInt32(controlKey | cmdKey), "carbonModifiers should map control+command")
        assert(ModifierCombination.option.cgEventFlags == .maskAlternate, "option should map to maskAlternate")
        assert(ModifierCombination.option.nsEventFlags == .option, "option should map to NSEvent .option")
        assert(ModifierCombination.option.carbonModifiers == UInt32(optionKey), "option should map to Carbon optionKey")

        // MARK: - Model: display string order (⌃⌥⇧⌘)

        assert(combo.displayString == "⌃⌘", "display should be ⌃⌘ for control+command")
        assert(
            ModifierCombination([.command, .shift, .option, .control]).displayString == "⌃⌥⇧⌘",
            "display order should be control, option, shift, command"
        )

        // MARK: - Persistence: default, round-trip, and invalid fallback (per store key)

        let defaults = UserDefaults.standard
        for key in [UserDefaultsKeys.mouseGestureModifiers, UserDefaultsKeys.zoneNavigationModifiers] {
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
                ModifierCombinationPreferences.load(key: key) == .defaultModifiers,
                "load(\(key)) should return the default when unset"
            )

            let saved: ModifierCombination = [.option, .shift]
            defaults.set(saved.rawValue, forKey: key)
            assert(
                ModifierCombinationPreferences.load(key: key) == saved,
                "a valid saved combination should round-trip for \(key)"
            )

            defaults.set(ModifierCombination.command.rawValue, forKey: key)
            assert(
                ModifierCombinationPreferences.load(key: key) == .defaultModifiers,
                "an invalid persisted combination should fall back to the default for \(key)"
            )
        }

        // MARK: - update() ignores invalid combinations; the stores are independent

        let mouseKey = UserDefaultsKeys.mouseGestureModifiers
        let mousePreviousValue = defaults.object(forKey: mouseKey)
        let mouseBefore = ModifierCombinationPreferences.mouseGestures.modifiers
        let zoneNavigationBefore = ModifierCombinationPreferences.zoneNavigation.modifiers

        ModifierCombinationPreferences.mouseGestures.update([.option, .shift])
        assert(
            ModifierCombinationPreferences.mouseGestures.modifiers == [.option, .shift],
            "update should accept a valid combination"
        )
        ModifierCombinationPreferences.mouseGestures.update(.command)
        assert(
            ModifierCombinationPreferences.mouseGestures.modifiers == [.option, .shift],
            "update should ignore an invalid (single-modifier) combination"
        )
        assert(
            ModifierCombinationPreferences.zoneNavigation.modifiers == zoneNavigationBefore,
            "updating one store should not affect the other"
        )

        // Restore the live store and the exact on-disk value.
        ModifierCombinationPreferences.mouseGestures.update(mouseBefore)
        if let mousePreviousValue {
            defaults.set(mousePreviousValue, forKey: mouseKey)
        } else {
            defaults.removeObject(forKey: mouseKey)
        }

        if allPassed {
            print("ModifierCombinationPreferencesTests: all tests passed")
        }
        return allPassed
    }
}
