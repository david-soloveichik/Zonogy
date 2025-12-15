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

    private enum ScoringConstants {
        static let matchExponent: Double = 2.0
        static let frecencyMultiplier: Double = 2.0
    }

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
            // Empty query: show all items sorted by pure frecency
            let scoringNow = Date()
            let scoredItems = allItems.map { item in
                let globalScore = usageStore.scores(itemURL: item.url, query: "", now: scoringNow).global
                return (item: item, globalScore: globalScore)
            }

            filteredItems = scoredItems
                .sorted { lhs, rhs in
                    if lhs.globalScore != rhs.globalScore { return lhs.globalScore > rhs.globalScore }
                    return lhs.item.displayName.localizedCaseInsensitiveCompare(rhs.item.displayName) == .orderedAscending
                }
                .map(\.item)
        } else {
            // Non-empty query: filter with match quality scoring
            let scoringNow = Date()

            // Filter and compute match quality
            let matchedItems: [(item: LaunchItem, matchScore: Double)] = allItems.compactMap { item in
                // Try display name first
                let displayResult = SubsequenceMatcher.scoreMatch(query: trimmedQuery, candidate: item.displayName)
                if displayResult.isMatch {
                    return (item, displayResult.score)
                }
                // Try alias
                if let alias = item.alias {
                    let aliasResult = SubsequenceMatcher.scoreMatch(query: trimmedQuery, candidate: alias)
                    if aliasResult.isMatch {
                        return (item, aliasResult.score)
                    }
                }
                return nil
            }

            // Compute scores; per-query frecency has priority over global frecency, with global as tie-breaker.
            let scoredItems = matchedItems.map { (item, matchScore) in
                let scores = usageStore.scores(itemURL: item.url, query: trimmedQuery, now: scoringNow)
                let weightedMatchScore = pow(matchScore, ScoringConstants.matchExponent)
                let perQueryFinalScore = weightedMatchScore * (1.0 + ScoringConstants.frecencyMultiplier * scores.perQuery)
                let globalFinalScore = weightedMatchScore * (1.0 + ScoringConstants.frecencyMultiplier * scores.global)
                return (item: item, perQuery: scores.perQuery, perQueryFinalScore: perQueryFinalScore, globalFinalScore: globalFinalScore)
            }

            filteredItems = scoredItems
                .sorted { lhs, rhs in
                    if lhs.perQuery != rhs.perQuery {
                        if lhs.perQueryFinalScore != rhs.perQueryFinalScore { return lhs.perQueryFinalScore > rhs.perQueryFinalScore }
                        // Extremely rare: different per-query scores but same final score.
                        return lhs.perQuery > rhs.perQuery
                    }

                    if lhs.globalFinalScore != rhs.globalFinalScore { return lhs.globalFinalScore > rhs.globalFinalScore }
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

        // Record frecency for the app
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstItemKey = filteredItems.first.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path }
        let selectedItemKey = resolved.path
        let recordQueryPreference = !trimmedQuery.isEmpty && firstItemKey != nil && firstItemKey != selectedItemKey
        usageStore.recordLaunch(query: trimmedQuery, itemURL: resolved, recordQueryPreference: recordQueryPreference)
        updateFilteredItems(preserveSelection: true)

        // Get windows from Zonogy's tracking (allow drilling into any running app)
        let windows = windowProvider?.windowsForApp(bundleIdentifier: bundleId) ?? []

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
            let matchedItems: [(index: Int, item: LauncherWindowItem, matchScore: Double)] = windowItems
                .enumerated()
                .compactMap { index, item in
                    let result = SubsequenceMatcher.scoreMatch(query: trimmedQuery, candidate: item.title)
                    guard result.isMatch else { return nil }
                    let weightedMatchScore = pow(result.score, ScoringConstants.matchExponent)
                    return (index: index, item: item, matchScore: weightedMatchScore)
                }

            filteredWindowItems = matchedItems
                .sorted { lhs, rhs in
                    if lhs.matchScore != rhs.matchScore { return lhs.matchScore > rhs.matchScore }
                    return lhs.index < rhs.index
                }
                .map(\.item)
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
