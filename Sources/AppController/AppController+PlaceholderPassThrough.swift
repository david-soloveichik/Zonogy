import Foundation
import AppKit

/// Detects unmanaged windows stuck behind placeholder windows and punches pass-through holes
/// into the placeholders' click-catching background so those windows remain clickable.
extension AppController {
    /// Schedule a pass-through refresh for the next runloop turn (coalescing repeated requests).
    /// Event-driven (no polling): requested after full zone syncs (which re-front placeholders),
    /// after unmanaged-focus state updates (which follow app activation and focused-window
    /// changes), shortly after a placeholder press ends (the click raises its panel; see
    /// `placeholderPressEnded`), after app terminations (which can remove unmanaged windows
    /// without any sync), and shortly after any global click while holes are active (see
    /// `installPlaceholderPassThroughClickMonitor`). Unmanaged windows that move or close
    /// without any such event leave a stale region until the next trigger — at worst until
    /// the next click anywhere, since stale regions only matter when clicked.
    /// The refresh must not run in the same runloop turn that issues an ordering change:
    /// a same-turn `CGWindowListCopyWindowInfo` would still report the pre-change z-order.
    internal func schedulePlaceholderPassThroughRefresh(reason: String) {
        guard !placeholderPassThroughRefreshScheduled else {
            return
        }
        placeholderPassThroughRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placeholderPassThroughRefreshScheduled = false
            self.refreshPlaceholderPassThrough(reason: reason)
        }
    }

    /// Recompute the pass-through regions on every active placeholder from the current
    /// WindowServer snapshot.
    private func refreshPlaceholderPassThrough(reason: String) {
        let placeholders = placeholderCoordinator.allActivePlaceholders()
        guard !placeholders.isEmpty else {
            placeholderPassThroughHasHoles = false
            return
        }
        guard let rows = WindowServerWindowList.onScreenWindowRowsFrontToBack() else {
            return
        }

        let managedCgWindowIds = Set(windowController.allWindows.map { $0.backing.cgWindowId })
        let zonogyPid = getpid()

        var anyHoles = false
        for placeholder in placeholders {
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: placeholder.cgWindowId,
                rowsFrontToBack: rows,
                zonogyPid: zonogyPid,
                managedCgWindowIds: managedCgWindowIds
            )
            anyHoles = anyHoles || !holes.isEmpty
            let cocoaScreenRects = holes.map {
                CoordinateConversion.accessibilityToCocoa(
                    accessibilityFrame: $0,
                    primaryScreenBounds: primaryScreenBounds
                )
            }
            if placeholder.setPassThroughRegions(cocoaScreenRects: cocoaScreenRects) {
                let screenIndex = screenContextStore.loggingIndex(for: placeholder.screenDisplayId)
                Logger.debug(
                    "Placeholder pass-through updated for zone \(placeholder.zoneIndex) on screen \(screenIndex): " +
                        "\(holes.count) hole(s) (reason: \(reason))"
                )
            }
        }
        placeholderPassThroughHasHoles = anyHoles
    }

    /// While any hole is active, clicks in other apps can change what the hole should cover
    /// (raise the window under it, hit a stale region over the desktop or an already-active
    /// app) without producing any focus or sync event. A global mouse-up monitor re-checks
    /// after such clicks; like the placeholder press path, it waits out the window server's
    /// asynchronous click-raise. Installed once at startup; the hole-free fast path is a
    /// single boolean test.
    internal func installPlaceholderPassThroughClickMonitor() {
        guard placeholderPassThroughMouseUpMonitor == nil else {
            return
        }
        placeholderPassThroughMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self, self.placeholderPassThroughHasHoles else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.schedulePlaceholderPassThroughRefresh(reason: "global-click")
            }
        }
    }
}
