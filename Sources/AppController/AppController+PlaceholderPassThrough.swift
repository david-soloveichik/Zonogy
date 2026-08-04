import Foundation
import AppKit

/// Detects windows stuck behind placeholder windows and desktop icons under them, and punches
/// pass-through holes into the placeholders' click-catching background so both remain clickable.
extension AppController {
    /// Schedule a pass-through refresh for the next runloop turn (coalescing repeated requests).
    /// Event-driven (no polling): requested after full zone syncs (which re-front placeholders),
    /// after unmanaged-focus state updates (which follow app activation and focused-window
    /// changes), shortly after a placeholder press ends (the click raises its panel; see
    /// `placeholderPressEnded`), after app terminations (which can remove windows
    /// without any sync), shortly after any global click while holes are active (see
    /// `installPlaceholderPassThroughClickMonitor`), and after debounced Desktop folder or
    /// volume-mount changes (see `DesktopChangeWatchService`). Windows that move or close
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
        // Desktop events (volume unmounts, folder writes) can arrive around sleep, and the
        // refresh performs synchronous AX calls into Finder, which can hang until the session
        // is ready. Skip entirely; the post-wake recovery's zone syncs reschedule a refresh.
        if shouldIgnoreDueToSleepWake(event: "placeholder-pass-through-refresh") {
            return
        }
        let placeholders = placeholderCoordinator.allActivePlaceholders()
        guard !placeholders.isEmpty else {
            placeholderPassThroughHasHoles = false
            return
        }
        guard let rows = WindowServerWindowList.onScreenWindowRowsFrontToBack() else {
            return
        }

        let zonogyPid = getpid()
        let desktopIconFrames = currentDesktopIconFrames()

        var anyHoles = false
        for placeholder in placeholders {
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: placeholder.cgWindowId,
                rowsFrontToBack: rows,
                zonogyPid: zonogyPid,
                desktopIconFrames: desktopIconFrames
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

    /// How long a successful desktop-icon read stays fresh. Icon-frame invalidation is
    /// event-driven — desktop-change notifications (file events including Finder's
    /// icon-position writes, volume mounts, Finder relaunch) and display changes clear
    /// `lastDesktopIconFramesReadTime` — so clicks reuse the cached frames and the
    /// steady-state click re-check does no Finder AX work. Expiry does not itself schedule
    /// a refresh; it only caps how long a later refresh may reuse the cache, bounding the
    /// staleness of any reflow no event catches, which self-heals on the click after the
    /// stale one.
    private static let desktopIconFramesFreshnessSeconds: TimeInterval = 5.0

    /// Desktop icon frames for the current refresh: a fresh read when the cache is stale,
    /// otherwise the cached snapshot. When Finder's hierarchy is transiently unreadable
    /// (mid-relaunch, AX hiccup) the last successful snapshot is kept — otherwise valid
    /// holes would vanish and, if they were the only holes, disable the global click
    /// re-check — and the timestamp is left stale so the next refresh retries.
    private func currentDesktopIconFrames() -> [CGRect] {
        if let readTime = lastDesktopIconFramesReadTime,
           Date().timeIntervalSince(readTime) < Self.desktopIconFramesFreshnessSeconds {
            return lastKnownDesktopIconFrames
        }
        guard let frames = DesktopIconAccessibility.iconFrames() else {
            return lastKnownDesktopIconFrames
        }
        lastKnownDesktopIconFrames = frames
        lastDesktopIconFramesReadTime = Date()
        return frames
    }

    /// While any hole is active, clicks in other apps can change what the hole should cover
    /// (raise the window under it, hit a stale region over the desktop or an already-active
    /// app) without producing any focus or sync event. A global mouse-up monitor re-checks
    /// after such clicks; like the placeholder press path, it waits out the window server's
    /// asynchronous click-raise. Icon movement needs no mouse tracking: Finder persists
    /// desktop icon positions at drag-drop time, which `DesktopChangeWatchService` observes.
    /// Installed once at startup; the hole-free fast path is a single boolean test.
    internal func installPlaceholderPassThroughClickMonitor() {
        guard placeholderPassThroughMouseUpMonitor == nil else {
            return
        }
        placeholderPassThroughMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] _ in
            guard let self, self.placeholderPassThroughHasHoles else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.schedulePlaceholderPassThroughRefresh(reason: "global-click")
            }
        }
    }
}
