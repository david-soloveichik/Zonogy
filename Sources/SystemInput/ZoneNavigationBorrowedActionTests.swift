import Carbon
import Foundation

/// Guardrail tests for how the zone-navigation gesture borrows its action keys from the shortcuts.
enum ZoneNavigationBorrowedActionTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ZoneNavigationBorrowedActionTests: \(message)")
                allPassed = false
            }
        }

        typealias Action = KeyboardShortcutPreferences.ShortcutAction
        typealias Borrowed = ZoneNavigationInterceptor.BorrowedAction
        func keys(_ bindings: [Action: Int]) -> [CGKeyCode: Borrowed] {
            Borrowed.keys { action in
                bindings[action].map { KeyboardShortcut(keyCode: UInt32($0), modifiers: UInt32(cmdKey)) }
            }
        }

        // Distinct bindings each borrow their own key.
        let distinct = keys([
            .moveFocusedWindowToTargetZone: kVK_Return, .showLauncher: kVK_Space, .addZone: kVK_ANSI_Equal,
            .removeZone: kVK_ANSI_Minus, .minimizeActiveWindow: kVK_ANSI_M,
        ])
        assert(distinct[CGKeyCode(kVK_Return)] == .move, "Return borrows Move")
        assert(distinct[CGKeyCode(kVK_Space)] == .showLauncher, "Space borrows Show Launcher")
        assert(distinct[CGKeyCode(kVK_ANSI_Equal)] == .addZone, "= borrows Add Zone")
        assert(distinct[CGKeyCode(kVK_ANSI_Minus)] == .removeZone, "- borrows Remove Zone")
        assert(distinct[CGKeyCode(kVK_ANSI_M)] == .minimize, "M borrows Minimize")
        assert(distinct.count == 5, "five distinct bindings give five borrowed keys")

        // A key two shortcuts share goes to the earlier claim; the later shortcut borrows nothing.
        let shared = keys([.moveFocusedWindowToTargetZone: kVK_Return, .minimizeActiveWindow: kVK_Return, .addZone: kVK_ANSI_Equal])
        assert(shared[CGKeyCode(kVK_Return)] == .move, "a shared key belongs to the earlier claim (Move before Minimize)")
        assert(shared.count == 2, "the later claim on a shared key borrows nothing")

        // An unbound shortcut borrows nothing.
        let unbound = keys([.showLauncher: kVK_Space])
        assert(unbound.count == 1 && unbound[CGKeyCode(kVK_Space)] == .showLauncher, "only bound shortcuts borrow a key")

        // Only Move and Show Launcher end the gesture; the others keep it engaged.
        for action in Borrowed.allCases {
            let expected = action == .move || action == .showLauncher
            assert(action.endsGesture == expected, "\(action) should \(expected ? "end" : "keep") the gesture")
        }

        if allPassed {
            print("ZoneNavigationBorrowedActionTests: all tests passed")
        }
        return allPassed
    }
}
