/// The keys on the keycaps of the tour's scenes. A scene's file carries a token of specs/TOUR-SCRIPT.md, such
/// as "{add zone}", on each keycap for keys the user can change, and the tour puts the current keys in its
/// place, or the token's words while that shortcut is unset.
import Foundation

enum TourKeycaps {
    /// Each token a keycap can carry, with the keys it stands for now.
    private static let keys: [String: () -> String?] = [
        "add zone": { shortcut(.addZone)?.displayString },
        "minimize": { shortcut(.minimizeActiveWindow)?.displayString },
        "one zone": { shortcut(.collapseToOneZone)?.displayString },
        "clear": { shortcut(.clearOrResetZones)?.displayString },
        "navigation keys": { ModifierCombinationPreferences.zoneNavigation.modifiers.displayString },
        // An action inside the zone navigation gesture borrows the key of its shortcut.
        "move key": { shortcut(.moveFocusedWindowToTargetZone)?.keyDisplayString },
        "add key": { shortcut(.addZone)?.keyDisplayString },
    ]

    /// The scene `svg` with each keycap's token replaced by the keys it stands for.
    static func fill(_ svg: String) -> String {
        keys.reduce(svg) { svg, token in
            svg.replacingOccurrences(of: ">{\(token.key)}<", with: ">\(capText(token.value() ?? token.key))<")
        }
    }

    private static func shortcut(_ action: KeyboardShortcutPreferences.ShortcutAction) -> KeyboardShortcut? {
        KeyboardShortcutPreferences.shared.shortcut(for: action)
    }

    /// Keys as their cap shows them. The scene sets a cap's text at 14 points and a single key at 18, as on
    /// the arrows; keys longer than any default are set smaller, so they stay on their cap.
    private static func capText(_ keys: String) -> String {
        let escaped = keys.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        switch keys.count {
        case 1: return #"<tspan font-size="18">\#(escaped)</tspan>"#
        case 2...5: return escaped
        default: return #"<tspan font-size="11">\#(escaped)</tspan>"#
        }
    }
}
