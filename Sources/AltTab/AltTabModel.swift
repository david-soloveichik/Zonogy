/// State management for the AltTab window switcher

import Foundation

final class AltTabModel: ObservableObject {
    /// All managed windows ordered by recency (most recent first)
    let windows: [LauncherWindowItem]

    /// Currently selected index in the windows list
    @Published var selectedIndex: Int = 0

    /// The currently selected window
    var selectedWindow: LauncherWindowItem? {
        guard selectedIndex >= 0, selectedIndex < windows.count else { return nil }
        return windows[selectedIndex]
    }

    init(windows: [LauncherWindowItem]) {
        self.windows = windows
    }

    /// Move selection to next window (wraps to beginning)
    func selectNext() {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % windows.count
    }

    /// Move selection to previous window (wraps to end)
    func selectPrevious() {
        guard !windows.isEmpty else { return }
        selectedIndex = selectedIndex == 0 ? windows.count - 1 : selectedIndex - 1
    }
}
