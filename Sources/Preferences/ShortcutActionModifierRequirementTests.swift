import Carbon
import Foundation

/// Guardrail test locking which shortcut actions require a modifier — the hold-to-commit choosers
/// (CmdTab, WinShot) and Window-Focus navigation. These commit on modifier release, so a
/// modifier-free binding (e.g. a bare function key) would have no release to detect.
enum ShortcutActionModifierRequirementTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ShortcutActionModifierRequirementTests: \(message)")
                allPassed = false
            }
        }

        typealias Action = KeyboardShortcutPreferences.ShortcutAction

        let expectedRequiresModifier: Set<Action> = [
            .showCmdTab, .showCmdTabCurrentApp, .showWinShotChooser,
            .focusWindowUp, .focusWindowDown, .focusWindowLeft, .focusWindowRight,
        ]

        for action in Action.allCases {
            let expected = expectedRequiresModifier.contains(action)
            assert(
                action.requiresModifier == expected,
                "\(action.rawValue).requiresModifier should be \(expected)"
            )
        }

        // accepts(): modifier-bearing bindings are always accepted.
        assert(
            Action.showCmdTab.accepts(keyCode: kVK_Tab, modifiers: UInt32(cmdKey)),
            "a modifier-bearing binding should be accepted for a hold-to-commit action"
        )

        // accepts(): a bare function key is allowed only for non-hold-to-commit actions.
        assert(
            Action.addZone.accepts(keyCode: kVK_F5, modifiers: 0),
            "a bare function key should be accepted for a non-hold-to-commit action"
        )
        assert(
            !Action.showCmdTab.accepts(keyCode: kVK_F5, modifiers: 0),
            "a bare function key should be rejected for a hold-to-commit action"
        )
        assert(
            !Action.showWinShotChooser.accepts(keyCode: kVK_F5, modifiers: 0),
            "a bare function key should be rejected for the WinShot switcher"
        )

        // accepts(): a bare non-function key is rejected for any action.
        assert(
            !Action.addZone.accepts(keyCode: kVK_ANSI_A, modifiers: 0),
            "a bare non-function key should be rejected even for a non-hold-to-commit action"
        )

        // accepts(): only recognized modifier bits count — a stray bit (caps-lock) isn't a modifier.
        assert(
            !Action.showCmdTab.accepts(keyCode: kVK_Tab, modifiers: UInt32(alphaLock)),
            "an unrecognized-only modifier should not satisfy a hold-to-commit action"
        )

        if allPassed {
            print("ShortcutActionModifierRequirementTests: all tests passed")
        }
        return allPassed
    }
}
