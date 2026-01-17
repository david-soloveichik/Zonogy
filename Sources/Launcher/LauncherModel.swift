/// State management for the launcher, integrated with Zonogy's window management

import AppKit
import Foundation

/// Protocol for providing window information from Zonogy's window controller
protocol LauncherWindowProvider: AnyObject {
    func windowsForApp(bundleIdentifier: String) -> [LauncherWindowItem]
    func windowCount(for bundleIdentifier: String) -> Int
    func isDefaultWindowInZone(forBundleIdentifier bundleId: String) -> Bool
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            switch mode {
            case .appList:
                updateFilteredItems(preserveSelection: false)
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
    @Published private(set) var appsWithDefaultWindowInZone: Set<URL> = []
    @Published private(set) var focusSearchFieldToken: Int = 0

    var isAppHeaderSelected: Bool {
        if case .windowList = mode {
            return selectedWindowId == nil
        }
        return false
    }

    weak var windowProvider: LauncherWindowProvider? {
        didSet {
            refreshDefaultWindowZoneStatus()
        }
    }

    private var windowItems: [LauncherWindowItem] = []
    private var savedAppQuery: String = ""
    private var allItems: [LaunchItem] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private var usageStore: LaunchItemUsageStore { LaunchItemUsageStore.shared }

    init() {
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
        refreshDefaultWindowZoneStatus()
    }

    func refreshDefaultWindowZoneStatus() {
        var result: Set<URL> = []
        for url in runningAppURLs {
            guard let bundle = Bundle(url: url),
                  let bundleId = bundle.bundleIdentifier,
                  windowProvider?.isDefaultWindowInZone(forBundleIdentifier: bundleId) == true else {
                continue
            }
            result.insert(url)
        }
        appsWithDefaultWindowInZone = result
    }

    func reloadItems() {
        allItems = LauncherAppCache.shared.cachedItems()
        updateFilteredItems(preserveSelection: false)
    }

    func requestSearchFieldFocus() {
        focusSearchFieldToken &+= 1
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

        // Always record selection for non-empty queries
        if !trimmedQuery.isEmpty {
            usageStore.recordSelection(query: trimmedQuery, itemURL: resolved)
        }

        updateFilteredItems(preserveSelection: true)
        return resolved
    }

    private func updateFilteredItems(preserveSelection: Bool) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSelection = preserveSelection ? selectedItemURL : nil

        if trimmedQuery.isEmpty {
            // Empty query: sort by recency then alphabetical
            let scoredItems = allItems.map { item -> (item: LaunchItem, recencyRank: Int) in
                let bundleId = Bundle(url: item.url)?.bundleIdentifier ?? ""
                let recencyRank = usageStore.recencyRank(bundleIdentifier: bundleId)
                return (item: item, recencyRank: recencyRank)
            }

            filteredItems = scoredItems
                .sorted { lhs, rhs in
                    if lhs.recencyRank != rhs.recencyRank { return lhs.recencyRank < rhs.recencyRank }
                    return lhs.item.displayName.localizedCaseInsensitiveCompare(rhs.item.displayName) == .orderedAscending
                }
                .map(\.item)
        } else {
            // Non-empty query: filter with match quality, then sort by spec order
            // 1. Per-query count (desc)
            // 2. Match quality (desc)
            // 3. Recency rank (asc)
            // 4. Alphabetical

            // Filter and compute match quality
            let normalizedQuery = trimmedQuery.lowercased()
            let matchedItems: [(item: LaunchItem, matchScore: Double)] = allItems.compactMap { item in
                // Check for exact alias match first (gets maximum score 1.0)
                if let alias = item.alias, alias.lowercased() == normalizedQuery {
                    return (item, 1.0)
                }

                // Try display name
                let displayResult = SubsequenceMatcher.scoreMatch(query: trimmedQuery, candidate: item.displayName)
                if displayResult.isMatch {
                    // Also check alias for potentially better score
                    if let alias = item.alias {
                        let aliasResult = SubsequenceMatcher.scoreMatch(query: trimmedQuery, candidate: alias)
                        if aliasResult.isMatch && aliasResult.score > displayResult.score {
                            return (item, aliasResult.score)
                        }
                    }
                    return (item, displayResult.score)
                }

                // Try alias as fallback
                if let alias = item.alias {
                    let aliasResult = SubsequenceMatcher.scoreMatch(query: trimmedQuery, candidate: alias)
                    if aliasResult.isMatch {
                        return (item, aliasResult.score)
                    }
                }
                return nil
            }

            // Compute all scoring components
            let scoredItems = matchedItems.map { (item, matchScore) -> (item: LaunchItem, perQueryCount: Int, combinedScore: Double) in
                let itemKey = LaunchItemUsageStore.normalizedItemKey(for: item.url)
                let perQueryCount = usageStore.perQueryCount(itemKey: itemKey, query: trimmedQuery)
                let matchQuality = matchScore * matchScore  // squared for emphasis
                let bundleId = Bundle(url: item.url)?.bundleIdentifier ?? ""
                let recencyRank = usageStore.recencyRank(bundleIdentifier: bundleId)
                // Never-used apps (Int.max) treated as rank 50 for smooth continuity
                let effectiveRank = Double(recencyRank == Int.max ? 50 : recencyRank)
                let recencyScore = 1.0 / (1.0 + 0.03 * effectiveRank)
                let combinedScore = 0.7 * matchQuality + 0.3 * recencyScore
                return (item: item, perQueryCount: perQueryCount, combinedScore: combinedScore)
            }

            filteredItems = scoredItems
                .sorted { lhs, rhs in
                    // 1. Per-query count (descending)
                    if lhs.perQueryCount != rhs.perQueryCount { return lhs.perQueryCount > rhs.perQueryCount }
                    // 2. Combined score (descending) - blends match quality and recency
                    if lhs.combinedScore != rhs.combinedScore { return lhs.combinedScore > rhs.combinedScore }
                    // 3. Alphabetical (tiebreaker)
                    return lhs.item.displayName.localizedCaseInsensitiveCompare(rhs.item.displayName) == .orderedAscending
                }
                .map(\.item)
        }

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

        // Record selection for the app (drill-down counts as activation per spec)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            usageStore.recordSelection(query: trimmedQuery, itemURL: resolved)
        }
        updateFilteredItems(preserveSelection: true)

        // Get windows from Zonogy's tracking (allow drilling into any running app)
        let windows = windowProvider?.windowsForApp(bundleIdentifier: bundleId) ?? []

        savedAppQuery = query
        mode = .windowList(bundleIdentifier: bundleId, appName: item.displayName)
        windowModeAppIcon = item.icon ?? LauncherAppCache.shared.icon(for: item.url)
        windowItems = sortWindowsNotInZoneFirst(windows)
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
            let matchedItems: [(index: Int, item: LauncherWindowItem, matchScore: Double)] = windowItems
                .enumerated()
                .compactMap { index, item in
                    let result = SubsequenceMatcher.scoreMatch(query: trimmedQuery, candidate: item.title)
                    guard result.isMatch else { return nil }
                    let weightedMatchScore = result.score * result.score
                    return (index: index, item: item, matchScore: weightedMatchScore)
                }

            let sorted = matchedItems
                .sorted { lhs, rhs in
                    if lhs.matchScore != rhs.matchScore { return lhs.matchScore > rhs.matchScore }
                    return lhs.index < rhs.index
                }
                .map(\.item)
            filteredWindowItems = sortWindowsNotInZoneFirst(sorted)
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

    /// Reorders windows: not-in-zone first, then in-zone, preserving relative order within each group
    private func sortWindowsNotInZoneFirst(_ windows: [LauncherWindowItem]) -> [LauncherWindowItem] {
        windows.filter { !$0.isInZone } + windows.filter { $0.isInZone }
    }

}
