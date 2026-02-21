/// State management for the CmdTab window switcher

import Foundation

final class CmdTabModel: ObservableObject {
    /// All managed windows ordered by recency (most recent first)
    let windows: [LauncherWindowItem]

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
