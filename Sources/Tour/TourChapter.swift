/// The tour's chapters, each a run of pages, listed in the tour window's toolbar. The Welcome chapter
/// introduces Zonogy on first launch; each of the others covers one feature.
import Foundation

enum TourChapter: String, CaseIterable {
    case welcome
    case keyboardNavigation
    case winShot

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .keyboardNavigation: return "Keyboard Navigation"
        case .winShot: return "WinShot Snapshots"
        }
    }

    /// The SF Symbol that stands for the chapter in the toolbar.
    var symbolName: String {
        switch self {
        case .welcome: return "hand.wave"
        case .keyboardNavigation: return "arrowkeys"
        case .winShot: return "camera"  // as on the Snapshots tab of Preferences
        }
    }

    /// The chapter's pages. Their text names shortcuts by their current bindings, so they are written
    /// anew each time the chapter opens.
    func pages() -> [TourPage] {
        switch self {
        case .welcome: return TourPage.welcomeChapter()
        case .keyboardNavigation: return TourPage.keyboardNavigationChapter()
        case .winShot: return TourPage.winShotChapter()
        }
    }
}
