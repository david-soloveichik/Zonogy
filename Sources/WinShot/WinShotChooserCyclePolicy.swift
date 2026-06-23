/// Pure policy deciding how a key press cycles the WinShot chooser, derived from the configured
/// "Show WinShot Switcher" shortcut (rather than a hardwired Control-Command-Tab).
import AppKit

enum WinShotChooserCyclePolicy {
    enum Direction {
        case next
        case previous
    }

    /// Returns the cycle direction for a key press while the chooser is open, or `nil` if the press
    /// isn't a cycle (wrong key, or the shortcut's modifiers aren't all held).
    ///
    /// Pressing the shortcut key while its modifiers are held cycles forward. Holding Shift in
    /// addition reverses direction — but only when the shortcut itself doesn't already include
    /// Shift. If it does, Shift is part of the required combination and back-cycling is impossible
    /// (by design).
    static func cycleDirection(
        pressedKeyCode: UInt16,
        heldModifiers: NSEvent.ModifierFlags,
        shortcutKeyCode: UInt16,
        shortcutModifiers: NSEvent.ModifierFlags
    ) -> Direction? {
        guard pressedKeyCode == shortcutKeyCode,
              heldModifiers.contains(shortcutModifiers) else {
            return nil
        }

        let shiftIsRequired = shortcutModifiers.contains(.shift)
        if !shiftIsRequired && heldModifiers.contains(.shift) {
            return .previous
        }
        return .next
    }
}
