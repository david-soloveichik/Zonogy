import Foundation
import AppKit

/// Keeps the Launcher from covering unmanaged windows that a placeholder lets clicks through to
/// (see `LauncherCoveredWindowPolicy`): auto-shows are suppressed over such a window, and every
/// pass-through refresh has the open Launcher yield to ones that arrived beneath it.
extension AppController {
    /// Unmanaged windows a Launcher at `cocoaFrame` would cover within the targeted display's
    /// empty tiling zones — and the targeted tiling zone itself, which may be emptying or, for
    /// an explicit open, occupied. A floating target has no area of its own, so only the empty
    /// tiling zones count then. The zone's departing occupant never qualifies: a minimizing
    /// window is still tracked, and a closing one is staged for deferred prune while the
    /// window server still lists it (see `managedOrPendingPruneCgWindowIds`) — either would
    /// otherwise veto the very auto-show its departure triggers. The price is that a window
    /// whose element vanished spuriously while it stays on screen is likewise passed over,
    /// so the Launcher may cover it until it is re-adopted.
    internal func unmanagedWindowsCoveredByLauncher(at cocoaFrame: CGRect, rows: [WindowServerWindowRow]) -> Set<Int> {
        guard let screenId = targetedScreenId(),
              let context = screenContexts[screenId] else {
            return []
        }
        var targetedZoneIndex: Int?
        if case .tiled(let key) = targetedZoneManager.targetedDestination, key.screenId == screenId {
            targetedZoneIndex = key.index
        }
        let zoneFrames = context.zoneController.allZones
            .filter { $0.occupantWindowId == nil || $0.index == targetedZoneIndex }
            .map { context.descriptor.screenToAccessibility(frameWithMargin(for: $0, in: context.zoneController)) }
        return LauncherCoveredWindowPolicy.coveredUnmanagedWindowNumbers(
            launcherFrame: CoordinateConversion.cocoaToAccessibility(cocoaFrame: cocoaFrame, primaryScreenBounds: primaryScreenBounds),
            zoneFrames: zoneFrames,
            rows: rows,
            zonogyPid: getpid(),
            managedWindowNumbers: windowController.managedOrPendingPruneCgWindowIds
        )
    }

    /// Whether a Launcher auto-shown at `cocoaFrame` would cover an unmanaged window. An
    /// unreadable window list does not hold the Launcher back: the rule is a courtesy.
    internal func autoShownLauncherWouldCoverUnmanagedWindow(at cocoaFrame: CGRect) -> Bool {
        guard let rows = WindowServerWindowList.onScreenWindowRowsFrontToBack() else {
            return false
        }
        return !unmanagedWindowsCoveredByLauncher(at: cocoaFrame, rows: rows).isEmpty
    }

    /// Dismiss the open Launcher if an unmanaged window it was not placed over now lies beneath it.
    internal func yieldLauncherToUnmanagedWindows(rows: [WindowServerWindowRow]) {
        guard let launcherFrame = launcherController.visibleFrame else {
            return
        }
        launcherController.yieldToUnmanagedWindows(unmanagedWindowsCoveredByLauncher(at: launcherFrame, rows: rows))
    }

    /// Record what the Launcher was just shown or moved over, so it yields only to later arrivals.
    func launcherControllerDidPlace(_ controller: LauncherController) {
        schedulePlaceholderPassThroughRefresh(reason: "launcher-placed")
    }
}
