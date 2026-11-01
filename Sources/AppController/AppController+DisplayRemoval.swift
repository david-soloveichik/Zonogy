/// Display removal: minimizes every managed window that was on a disconnected display. A window in
/// native full-screen cannot be minimized, and macOS would move its full-screen Space to a remaining
/// display instead, so it first leaves full-screen.
import AppKit

extension AppController {
    internal func handleRemovedScreens(
        _ removed: [ScreenContextStore.RebuildResult.RemovedContext],
        framesBeforeRemoval: [CGDirectDisplayID: CGRect]
    ) {
        for entry in removed {
            let displayId = entry.displayId

            // Snapshot all windows that currently report this displayId.
            let windowsOnDisplay = windowController.allWindows.filter {
                $0.screenDisplayId == displayId
            }

            // Clear placeholders for this display and close the windows.
            placeholderCoordinator.clearPlaceholdersForScreen(displayId)
            dropPendingWinShotOpenAfterFullScreenExit(on: displayId, reason: "display removed")

            let screenDescription = "\(entry.context.descriptor.localizedName) [screen \(screenContextStore.loggingIndex(for: displayId))]"
            let zoneCount = entry.context.zoneController.allZones.count
            Logger.debug("Handling removal of screen \(screenDescription) with \(zoneCount) zone(s)")

            // Save the arrangement the minimization below dismantles (auto-save mode permitting) and
            // hand the display's WinShot snapshots to its neighbor, while the zone state is intact.
            handleWinShotSnapshotsForRemovedScreen(entry.context, framesBeforeRemoval: framesBeforeRemoval)

            // Minimize every managed window that was on the removed display,
            // instead of reassigning it to another screen. We rely on the pre-snapshot
            // windowsOnDisplay so this is robust even if earlier syncs cleared
            // screenDisplayId for those windows. The display's tiling zones left with its
            // context, but its floating-zone booking did not; releasing it here keeps the
            // system's relocation of the minimizing window from re-booking it on another display.
            for managed in windowsOnDisplay {
                removeWindowFromAllZones(windowId: managed.windowId, reason: "display-removal", retarget: false, logIfUnassigned: false)
                if FullScreenTracker.isWindowFullScreen(element: managed.backing.element) {
                    Logger.debug("Window \(managed.windowId) from removed \(screenDescription) is in native full-screen; asking it to leave full-screen before minimizing it")
                    minimizeAfterLeavingFullScreen(managed)
                } else {
                    Logger.debug("Minimizing window \(managed.windowId) from removed \(screenDescription) due to display-removal policy")
                    minimizeWindowProgrammatically(managed, reason: "display-removal")
                }
            }
        }
    }

    /// Asks `managed` to leave native full-screen, then minimizes it once it is out of its full-screen
    /// Space and back on screen: macOS re-presents it a moment after the Space is torn down, undoing a
    /// minimize issued before then. The exit need not raise any event (its Space was not showing), so
    /// the window is checked every `fullScreenExitRecheckInterval` from the request, until
    /// `fullScreenExitTimeout`. Meanwhile it pauses no display (the full-screen tracker skips it), yet
    /// still counts as a full-screen window Zonogy must not move, and placement skips it.
    private func minimizeAfterLeavingFullScreen(_ managed: ManagedWindow) {
        guard FullScreenTracker.requestExitFullScreen(element: managed.backing.element) else {
            Logger.debug("Window \(managed.windowId) from a removed display refused to leave full-screen")
            return
        }
        let cgWindowId = CGWindowID(managed.backing.cgWindowId)
        windowsLeavingFullScreenToMinimize.insert(cgWindowId)
        minimizeOnceOutOfFullScreen(
            windowId: managed.windowId,
            cgWindowId: cgWindowId,
            deadline: Date().addingTimeInterval(fullScreenExitTimeout)
        )
    }

    private func minimizeOnceOutOfFullScreen(windowId: Int, cgWindowId: CGWindowID, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + fullScreenExitRecheckInterval) { [weak self] in
            // Membership ends the checks: cleared on sleep, removed once minimized or abandoned.
            guard let self, self.windowsLeavingFullScreenToMinimize.contains(cgWindowId) else { return }
            guard let managed = self.windowController.window(withId: windowId) else {
                self.windowsLeavingFullScreenToMinimize.remove(cgWindowId)
                return
            }
            if !SpaceQueries.isWindowInNativeFullScreenSpace(cgWindowId: cgWindowId),
               FullScreenTracker.isWindowOnScreen(cgWindowId: cgWindowId) == true {
                self.windowsLeavingFullScreenToMinimize.remove(cgWindowId)
                Logger.debug("Window \(windowId) from a removed display left full-screen; minimizing it")
                self.minimizeWindowProgrammatically(managed, reason: "display-removal")
            } else if Date() < deadline {
                self.minimizeOnceOutOfFullScreen(windowId: windowId, cgWindowId: cgWindowId, deadline: deadline)
            } else {
                self.windowsLeavingFullScreenToMinimize.remove(cgWindowId)
                Logger.debug("Window \(windowId) from a removed display did not leave full-screen within \(self.fullScreenExitTimeout)s; not minimizing it")
            }
        }
    }
}
