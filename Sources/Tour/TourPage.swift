/// One page of a tour chapter: its title, the scene it shows, and its text and controls.
import AppKit

struct TourPage {
    /// One line of a list. `lead` opens it in bold: what the line is about, or what to press.
    struct Point {
        let lead: String
        let text: String
    }

    enum Block {
        case paragraph(String)
        case points([Point])
        /// Something to do right now, on the windows beside the tour.
        case tryIt(String)
        /// Banners saying whether these permissions are granted, each with a button to its settings.
        case permissions(PermissionBannersView.Permissions)
        /// A checkbox for a setting: `isOn` reads it when the page is shown, and `set` stores a change.
        case toggle(title: String, isOn: () -> Bool, set: (Bool) -> Void)
        case button(title: String, action: () -> Void)
    }

    let title: String
    /// The animated picture above the text: the name of a file in Resources/Tour, without its extension.
    var scene: String?
    let blocks: [Block]

    /// Marks `keys` in a page's text, which sets them apart from the words around them (see TourPageView).
    static func keys(_ keys: String) -> String {
        "\(keysStart)\(keys)\(keysEnd)"
    }

    /// An action's shortcut in a page's text: its keys, marked, or the action by name while it has none.
    static func shortcutKeys(_ action: KeyboardShortcutPreferences.ShortcutAction) -> String {
        let shortcuts = KeyboardShortcutPreferences.shared
        return shortcuts.shortcut(for: action).map { keys($0.displayString) } ?? shortcuts.keyPhrase(for: action)
    }

    /// The private-use characters around marked keys. They are never shown.
    static let keysStart: Character = "\u{E000}", keysEnd: Character = "\u{E001}"

    /// Whether the page asks for Accessibility, which the pages after it need.
    var asksForAccessibility: Bool {
        blocks.contains {
            guard case .permissions(let permissions) = $0 else { return false }
            return permissions.contains(.accessibility)
        }
    }
}
