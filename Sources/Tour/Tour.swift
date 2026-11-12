/// Zonogy's tours, each a run of pages in the tour window: the Welcome tour introduces Zonogy on first
/// launch, and the WinShot tour covers snapshots, which are off until the user turns them on.
import Foundation

enum Tour {
    case welcome
    case winShot

    var windowTitle: String {
        switch self {
        case .welcome: return "Zonogy Welcome Tour"
        case .winShot: return "Zonogy WinShot Tour"
        }
    }

    /// The tour's pages. Their text names shortcuts by their current bindings, so they are written anew
    /// each time the tour opens.
    func pages() -> [TourPage] {
        switch self {
        case .welcome: return TourPage.welcomeTour()
        case .winShot: return TourPage.winShotTour()
        }
    }
}
