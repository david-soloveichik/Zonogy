import AppKit
import Carbon
import Foundation

/// Guardrail tests for WinShot chooser cycling derived from the configured shortcut.
enum WinShotChooserCyclePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotChooserCyclePolicyTests: \(message)")
                allPassed = false
            }
        }

        let tab = UInt16(kVK_Tab)
        let grave = UInt16(kVK_ANSI_Grave)

        // MARK: - Default shortcut: Control-Command-Tab

        let ctrlCmd: NSEvent.ModifierFlags = [.control, .command]

        assert(
            WinShotChooserCyclePolicy.cycleDirection(
                pressedKeyCode: tab, heldModifiers: ctrlCmd,
                shortcutKeyCode: tab, shortcutModifiers: ctrlCmd
            ) == .next,
            "holding the shortcut modifiers and pressing its key should cycle next"
        )

        assert(
            WinShotChooserCyclePolicy.cycleDirection(
                pressedKeyCode: tab, heldModifiers: [.control, .command, .shift],
                shortcutKeyCode: tab, shortcutModifiers: ctrlCmd
            ) == .previous,
            "adding Shift should reverse direction when the shortcut lacks Shift"
        )

        assert(
            WinShotChooserCyclePolicy.cycleDirection(
                pressedKeyCode: tab, heldModifiers: [.command],
                shortcutKeyCode: tab, shortcutModifiers: ctrlCmd
            ) == nil,
            "missing a required modifier should not cycle"
        )

        assert(
            WinShotChooserCyclePolicy.cycleDirection(
                pressedKeyCode: grave, heldModifiers: ctrlCmd,
                shortcutKeyCode: tab, shortcutModifiers: ctrlCmd
            ) == nil,
            "a different key should not cycle"
        )

        // MARK: - Custom shortcut: Option-Command-` (key/modifiers derived, not hardwired to Tab)

        let optCmd: NSEvent.ModifierFlags = [.option, .command]

        assert(
            WinShotChooserCyclePolicy.cycleDirection(
                pressedKeyCode: grave, heldModifiers: optCmd,
                shortcutKeyCode: grave, shortcutModifiers: optCmd
            ) == .next,
            "a custom shortcut key/modifiers should cycle next"
        )
        assert(
            WinShotChooserCyclePolicy.cycleDirection(
                pressedKeyCode: grave, heldModifiers: [.option, .command, .shift],
                shortcutKeyCode: grave, shortcutModifiers: optCmd
            ) == .previous,
            "Shift should reverse a custom shortcut that lacks Shift"
        )
        assert(
            WinShotChooserCyclePolicy.cycleDirection(
                pressedKeyCode: tab, heldModifiers: optCmd,
                shortcutKeyCode: grave, shortcutModifiers: optCmd
            ) == nil,
            "Tab should not cycle when the configured key is `"
        )

        // MARK: - Shortcut that already includes Shift: back-cycling is impossible (by design)

        let ctrlCmdShift: NSEvent.ModifierFlags = [.control, .command, .shift]

        assert(
            WinShotChooserCyclePolicy.cycleDirection(
                pressedKeyCode: tab, heldModifiers: ctrlCmdShift,
                shortcutKeyCode: tab, shortcutModifiers: ctrlCmdShift
            ) == .next,
            "when Shift is part of the shortcut it does not reverse — it stays forward"
        )

        if allPassed {
            print("WinShotChooserCyclePolicyTests: all tests passed")
        }
        return allPassed
    }
}
