/// One page of a tour: its title, the scene it shows, and its text and controls.
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
}
