import AppKit
import Foundation

/// Pinned resize-bar mode: per-screen state, dismissal, and monitor lifecycle.
extension AppController {
    internal func enterPinnedResizeBarMode(on screenId: CGDirectDisplayID, reason: String) {
        prunePinnedResizeBarScreens(reason: "enter-preflight")
        guard screenContexts[screenId] != nil else {
            return
        }
        let inserted = pinnedResizeBarScreenIds.insert(screenId).inserted
        syncPinnedResizeBarClickMonitor()
        Logger.debug(
            "Pinned resize bars \(inserted ? "entered" : "refreshed") on \(screenContextStore.logDescription(for: screenId)) (reason: \(reason))"
        )
        refreshResizeHandles()
    }

    internal func exitPinnedResizeBarMode(reason: String) {
        guard !pinnedResizeBarScreenIds.isEmpty else {
            return
        }
        let clearedScreens = pinnedResizeBarScreenIds
        pinnedResizeBarScreenIds.removeAll()
        syncPinnedResizeBarClickMonitor()
        let descriptions = clearedScreens
            .map { screenContextStore.logDescription(for: $0) }
            .sorted()
            .joined(separator: ", ")
        Logger.debug("Pinned resize bars exited on [\(descriptions)] (reason: \(reason))")
        refreshResizeHandles()
    }

    internal func exitPinnedResizeBarMode(on screenId: CGDirectDisplayID, reason: String) {
        guard pinnedResizeBarScreenIds.remove(screenId) != nil else {
            return
        }
        syncPinnedResizeBarClickMonitor()
        Logger.debug("Pinned resize bars exited on \(screenContextStore.logDescription(for: screenId)) (reason: \(reason))")
        refreshResizeHandles()
    }

    internal func isResizeHandlePinnedModeActive(on screenId: CGDirectDisplayID) -> Bool {
        pinnedResizeBarScreenIds.contains(screenId)
    }

    internal func prunePinnedResizeBarScreens(reason: String) {
        let validScreenIds = Set(screenContexts.keys)
        let pruned = pinnedResizeBarScreenIds.intersection(validScreenIds)
        guard pruned != pinnedResizeBarScreenIds else {
            return
        }
        pinnedResizeBarScreenIds = pruned
        syncPinnedResizeBarClickMonitor()
        Logger.debug("Pinned resize bars pruned to active screens (reason: \(reason))")
    }

    private func syncPinnedResizeBarClickMonitor() {
        guard !pinnedResizeBarScreenIds.isEmpty else {
            pinnedResizeBarClickMonitor?.stop()
            pinnedResizeBarClickMonitor = nil
            return
        }

        guard pinnedResizeBarClickMonitor == nil else {
            return
        }

        let monitor = ClickOutsideMonitor(
            windowsProvider: { [weak self] in
                self?.pinnedResizeBarMonitorWindows() ?? []
            },
            mode: .includeOwnApp
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.exitPinnedResizeBarMode(reason: "outside-zonogy-click")
            }
        }
        monitor.start()
        pinnedResizeBarClickMonitor = monitor
    }

    private func pinnedResizeBarMonitorWindows() -> [NSWindow] {
        NSApp.windows
    }
}
