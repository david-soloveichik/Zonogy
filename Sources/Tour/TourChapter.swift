/// The tour's chapters, each a run of pages, listed along the top of the tour window. The Welcome chapter
/// introduces Zonogy on first launch; each of the others covers one topic.
import Foundation

enum TourChapter: String, CaseIterable {
    case welcome
    case keyboard
    case winShot

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .keyboard: return "Keyboard"
        case .winShot: return "WinShot Snapshots"
        }
    }

    /// The chapter after this one, which Continue opens from this one's last page.
    var next: TourChapter? {
        let chapters = Self.allCases
        let index = chapters.firstIndex(of: self)! + 1
        return index < chapters.count ? chapters[index] : nil
    }

    /// The chapter's pages. Their text names shortcuts by their current bindings, so they are written
    /// anew each time the chapter opens.
    func pages() -> [TourPage] {
        switch self {
        case .welcome: return TourPage.welcomeChapter()
        case .keyboard: return TourPage.keyboardChapter()
        case .winShot: return TourPage.winShotChapter()
        }
    }
}
