/// State management for the CmdTab window switcher

import Foundation

final class CmdTabModel: ObservableObject {
    /// All managed windows ordered by recency (most recent first). Membership and order
    /// are fixed for the session; only each row's placed-in-zone flag is refreshed live.
    @Published private(set) var windows: [LauncherWindowItem]

    /// Whether selection wraps around at list boundaries
    let wrapsAround: Bool

    /// Currently selected index in the windows list
    @Published var selectedIndex: Int = 0

    /// The currently selected window
    var selectedWindow: LauncherWindowItem? {
        guard selectedIndex >= 0, selectedIndex < windows.count else { return nil }
        return windows[selectedIndex]
    }

    init(windows: [LauncherWindowItem], wrapsAround: Bool = false) {
        self.windows = windows
        self.wrapsAround = wrapsAround
    }

    /// Re-reads each row's placed-in-zone flag through the resolver so the window icon
    /// glyphs track minimizes, closes, and restores that land while the switcher is open.
    /// Publishes only on a real change.
    func refreshPlacementStates(isPlacedInZone: (Int) -> Bool) {
        let refreshed = windows.refreshingPlacement(isPlacedInZone: isPlacedInZone)
        if refreshed != windows {
            windows = refreshed
        }
    }

    /// Move selection to next window
    func selectNext() {
        guard !windows.isEmpty else { return }
        if wrapsAround {
            selectedIndex = (selectedIndex + 1) % windows.count
        } else {
            selectedIndex = min(selectedIndex + 1, windows.count - 1)
        }
    }

    /// Move selection to previous window
    func selectPrevious() {
        guard !windows.isEmpty else { return }
        if wrapsAround {
            selectedIndex = (selectedIndex - 1 + windows.count) % windows.count
        } else {
            selectedIndex = max(selectedIndex - 1, 0)
        }
    }
}
