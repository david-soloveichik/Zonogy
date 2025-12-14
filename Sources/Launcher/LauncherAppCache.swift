/// Shared in-memory cache for launcher applications with lazy icon loading.

import AppKit
import Foundation

@MainActor
final class LauncherAppCache {
    static let shared = LauncherAppCache()

    private var items: [LaunchItem] = []
    private var iconCache: [URL: NSImage] = [:]
    private var isLoaded = false
    private let appProvider = DefaultAppProvider()
    private let displayNameStyle: AppDisplayNameStyle = .preferred

    private init() {}

    /// Pre-loads the application list at startup (without icons for speed).
    func preload() async {
        guard !isLoaded else { return }

        let apps = await appProvider.discoverApplications(displayNameStyle: displayNameStyle, skipIcons: true)
        let configEntries = LauncherConfigurationStore.loadEntries()
        let combined = merge(apps: apps, configEntries: configEntries)

        items = combined.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        isLoaded = true

        Logger.debug("LauncherAppCache: Preloaded \(items.count) items")
    }

    /// Reloads the application list and clears the icon cache.
    /// Also reloads launcher-config.json for alias changes.
    func reload() async {
        iconCache.removeAll()

        let apps = await appProvider.discoverApplications(displayNameStyle: displayNameStyle, skipIcons: true)
        let configEntries = LauncherConfigurationStore.loadEntries()
        let combined = merge(apps: apps, configEntries: configEntries)

        items = combined.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        isLoaded = true

        Logger.debug("LauncherAppCache: Reloaded \(items.count) items, icon cache cleared")
    }

    /// Returns the cached items (empty if not yet loaded).
    func cachedItems() -> [LaunchItem] {
        return items
    }

    /// Returns whether the cache has been loaded.
    var hasLoaded: Bool {
        return isLoaded
    }

    /// Lazily loads and caches the icon for the given URL.
    func icon(for url: URL) -> NSImage? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()

        if let cached = iconCache[resolved] {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: resolved.path)
        iconCache[resolved] = icon
        return icon
    }

    // MARK: - Private

    private func merge(apps: [LaunchItem], configEntries: [LauncherConfigurationStore.Entry]) -> [LaunchItem] {
        var aliasByPath: [String: String] = [:]
        aliasByPath.reserveCapacity(configEntries.count)
        for entry in configEntries {
            guard let alias = entry.alias, !alias.isEmpty else { continue }
            aliasByPath[normalizedPath(for: entry.url)] = alias
        }

        let appPaths = Set(apps.map { normalizedPath(for: $0.url) })
        let appsWithAliases = apps.map { item in
            let key = normalizedPath(for: item.url)
            guard let alias = aliasByPath[key], !alias.isEmpty else { return item }
            return LaunchItem(url: item.url, displayName: item.displayName, icon: item.icon, kind: item.kind, alias: alias)
        }

        var extras: [LaunchItem] = []
        for entry in configEntries {
            let key = normalizedPath(for: entry.url)
            guard !appPaths.contains(key) else { continue }
            if let item = LaunchItemBuilder.makeItem(for: entry.url, displayNameStyle: displayNameStyle, alias: entry.alias, skipIcon: true) {
                extras.append(item)
            }
        }

        return appsWithAliases + extras
    }

    private func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
