/// State management for the launcher, integrated with Zonogy's window management

import AppKit
import Foundation

/// Protocol for providing window information from Zonogy's window controller
protocol LauncherWindowProvider: AnyObject {
    func windowsForApp(bundleIdentifier: String) -> [LauncherWindowItem]
    func windowCount(for bundleIdentifier: String) -> Int
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            switch mode {
            case .appList:
                updateFilteredItems(preserveSelection: true)
            case .windowList:
                updateFilteredWindowItems()
            }
        }
    }

    @Published private(set) var filteredItems: [LaunchItem] = []
    @Published var selectedItemURL: URL? {
        didSet {
            if case .appList = mode {
                updateWindowCountForSelectedApp()
            }
        }
    }

    @Published private(set) var mode: LauncherMode = .appList
    @Published private(set) var filteredWindowItems: [LauncherWindowItem] = []
    @Published var selectedWindowId: UUID?
    @Published private(set) var cachedWindowCount: Int?
    @Published private(set) var windowModeAppIcon: NSImage?
    @Published private(set) var runningAppURLs: Set<URL> = []

    var isAppHeaderSelected: Bool {
        if case .windowList = mode {
            return selectedWindowId == nil
        }
        return false
    }

    weak var windowProvider: LauncherWindowProvider?

    private var windowItems: [LauncherWindowItem] = []
    private var savedAppQuery: String = ""
    private var allItems: [LaunchItem] = []
    private let usageStore: LaunchItemUsageStore
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        usageStore: LaunchItemUsageStore = LaunchItemUsageStore()
    ) {
        self.usageStore = usageStore
        reloadItems()
        refreshRunningApps()
        setupWorkspaceObservers()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
    }

    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRunningApps()
            }
        }
        let terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRunningApps()
            }
        }
        workspaceObservers = [launchObserver, terminateObserver]
    }

    private func refreshRunningApps() {
        let running = NSWorkspace.shared.runningApplications
        runningAppURLs = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() })
    }

    func reloadItems() {
        allItems = LauncherAppCache.shared.cachedItems()
        updateFilteredItems(preserveSelection: false)
    }

    func moveSelection(by delta: Int) {
        guard !filteredItems.isEmpty else {
            selectedItemURL = nil
            return
        }

        let currentIndex = filteredItems.firstIndex { $0.url == selectedItemURL } ?? 0
        let nextIndex = min(max(0, currentIndex + delta), filteredItems.count - 1)
        selectedItemURL = filteredItems[nextIndex].url
    }

    /// Returns the selected item for launching
    func selectedItem() -> LaunchItem? {
        guard let url = selectedItemURL ?? filteredItems.first?.url else { return nil }
        return filteredItems.first { $0.url == url } ?? allItems.first { $0.url == url }
    }

    /// Record usage and return the item URL for launching
    func recordAndGetSelectedItem() -> URL? {
        guard let url = selectedItemURL ?? filteredItems.first?.url else { return nil }

        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstItemKey = filteredItems.first.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path }
        let selectedItemKey = resolved.path
        let recordQueryPreference = !trimmedQuery.isEmpty && firstItemKey != nil && firstItemKey != selectedItemKey
        usageStore.recordLaunch(query: trimmedQuery, itemURL: resolved, recordQueryPreference: recordQueryPreference)
        updateFilteredItems(preserveSelection: true)

        return resolved
    }

    private func updateFilteredItems(preserveSelection: Bool) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSelection = preserveSelection ? selectedItemURL : nil

        if trimmedQuery.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter { item in
                if SubsequenceMatcher.matches(query: trimmedQuery, candidate: item.displayName) {
                    return true
                }
                if let alias = item.alias, SubsequenceMatcher.matches(query: trimmedQuery, candidate: alias) {
                    return true
                }
                return false
            }
        }

        let scoringNow = Date()
        let scoredItems = filteredItems.map { item in
            (item: item, score: usageStore.combinedScore(itemURL: item.url, query: trimmedQuery, now: scoringNow))
        }

        filteredItems = scoredItems
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.item.displayName.localizedCaseInsensitiveCompare(rhs.item.displayName) == .orderedAscending
            }
            .map(\.item)

        if let previousSelection, filteredItems.contains(where: { $0.url == previousSelection }) {
            selectedItemURL = previousSelection
        } else {
            selectedItemURL = filteredItems.first?.url
        }
    }

    // MARK: - Window Navigation

    func updateWindowCountForSelectedApp() {
        guard let url = selectedItemURL,
              let item = filteredItems.first(where: { $0.url == url }),
              item.kind == .application,
              let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier else {
            cachedWindowCount = nil
            return
        }

        cachedWindowCount = windowProvider?.windowCount(for: bundleId)
    }

    func enterWindowMode() {
        guard let url = selectedItemURL,
              let item = filteredItems.first(where: { $0.url == url }),
              item.kind == .application,
              let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier else { return }

        // Record frecency for the app
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstItemKey = filteredItems.first.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path }
        let selectedItemKey = resolved.path
        let recordQueryPreference = !trimmedQuery.isEmpty && firstItemKey != nil && firstItemKey != selectedItemKey
        usageStore.recordLaunch(query: trimmedQuery, itemURL: resolved, recordQueryPreference: recordQueryPreference)
        updateFilteredItems(preserveSelection: true)

        // Get windows from Zonogy's tracking
        guard let windows = windowProvider?.windowsForApp(bundleIdentifier: bundleId),
              windows.count >= 2 else { return }

        savedAppQuery = query
        mode = .windowList(bundleIdentifier: bundleId, appName: item.displayName)
        windowModeAppIcon = item.icon ?? LauncherAppCache.shared.icon(for: item.url)
        windowItems = windows
        query = ""
        updateFilteredWindowItems()
    }

    func exitWindowMode() {
        guard case .windowList = mode else { return }
        mode = .appList
        windowModeAppIcon = nil
        windowItems = []
        filteredWindowItems = []
        selectedWindowId = nil
        query = savedAppQuery
        savedAppQuery = ""
    }

    func exitWindowModeAndClearSearch() {
        guard case .windowList = mode else { return }
        mode = .appList
        windowModeAppIcon = nil
        windowItems = []
        filteredWindowItems = []
        selectedWindowId = nil
        savedAppQuery = ""
        query = ""
    }

    private func updateFilteredWindowItems() {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedQuery.isEmpty {
            filteredWindowItems = windowItems
        } else {
            filteredWindowItems = windowItems.filter {
                SubsequenceMatcher.matches(query: trimmedQuery, candidate: $0.title)
            }
        }

        selectedWindowId = filteredWindowItems.first?.id
    }

    func moveWindowSelection(by delta: Int) {
        // Handle header selection (selectedWindowId == nil means header is selected)
        if selectedWindowId == nil {
            if delta > 0, let firstWindow = filteredWindowItems.first {
                // Moving down from header: select first window
                selectedWindowId = firstWindow.id
            }
            // Moving up from header: stay on header (do nothing)
            return
        }

        guard !filteredWindowItems.isEmpty else {
            selectedWindowId = nil
            return
        }

        let currentIndex = filteredWindowItems.firstIndex { $0.id == selectedWindowId } ?? 0

        if delta < 0 && currentIndex == 0 {
            // Moving up from first window: select header
            selectedWindowId = nil
            return
        }

        let nextIndex = min(max(0, currentIndex + delta), filteredWindowItems.count - 1)
        selectedWindowId = filteredWindowItems[nextIndex].id
    }

    /// Returns the selected window item
    func selectedWindowItem() -> LauncherWindowItem? {
        guard let id = selectedWindowId else { return nil }
        return filteredWindowItems.first { $0.id == id }
    }

    /// Returns the bundle identifier when in window mode (for activating the app header)
    func windowModeBundleIdentifier() -> String? {
        guard case .windowList(let bundleId, _) = mode else { return nil }
        return bundleId
    }

}
