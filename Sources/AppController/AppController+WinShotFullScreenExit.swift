/// WinShot on a display paused for native full-screen: the chosen arrangement takes the display's
/// full-screen window out of full-screen mode and opens once the display has left its full-screen
/// Space (or is dropped after a timeout).
import AppKit

extension AppController {
    /// True while `screenId` is paused for full-screen or still finishing a full-screen exit for a
    /// chosen arrangement. WinShot treats both alike: nothing is captured (transition-time state is
    /// not a valid arrangement) and a chosen arrangement goes through the wait.
    internal func isScreenInOrLeavingFullScreen(_ screenId: CGDirectDisplayID) -> Bool {
        isScreenPausedForFullScreen(screenId) || pendingWinShotOpensAfterFullScreenExit[screenId] != nil
    }

    /// Asks `screenId`'s native full-screen window to leave full-screen mode and remembers `snapshot`
    /// to open there afterward. While the display is still leaving full-screen for an earlier
    /// choice, a new choice simply replaces the arrangement that is waiting. Pauses for non-native
    /// full-screen have no Space to leave, so the arrangement is not opened.
    internal func openWinShotSnapshotAfterExitingFullScreen(
        _ snapshot: WinShotSnapshot,
        on screenId: CGDirectDisplayID,
        reason: String
    ) {
        let screenDescription = screenContextStore.logDescription(for: screenId)
        if var pending = pendingWinShotOpensAfterFullScreenExit[screenId] {
            Logger.debug("WinShot: snapshot \(snapshot.id) replaces snapshot \(pending.snapshotId) waiting for \(screenDescription) to leave full-screen")
            pending.snapshotId = snapshot.id
            pending.reason = reason
            pendingWinShotOpensAfterFullScreenExit[screenId] = pending
            return
        }
        guard let info = fullScreenTracker.fullScreenWindowInfo(for: screenId), info.isNativeFullScreen else {
            Logger.debug("WinShot: not opening snapshot \(snapshot.id) on \(screenDescription) (paused for non-native full-screen)")
            return
        }

        let bundleDesc = info.bundleIdentifier ?? "unknown"
        guard FullScreenTracker.requestExitFullScreen(element: info.element) else {
            Logger.debug(
                "WinShot: full-screen window (CGWindowID \(info.cgWindowId), bundle: \(bundleDesc)) refused to leave " +
                    "full-screen; not opening snapshot \(snapshot.id) on \(screenDescription)"
            )
            return
        }

        let token = UUID()
        let pending = PendingWinShotOpenAfterFullScreenExit(
            token: token,
            snapshotId: snapshot.id,
            reason: reason,
            fullScreenWindow: FullScreenElementInfo(pid: info.pid, cgWindowId: info.cgWindowId),
            timeout: DispatchWorkItem { [weak self] in
                guard let self, self.pendingWinShotOpensAfterFullScreenExit[screenId]?.token == token else { return }
                self.dropPendingWinShotOpenAfterFullScreenExit(
                    on: screenId,
                    reason: "did not leave full-screen within \(self.winShotFullScreenExitTimeout)s"
                )
            }
        )
        pendingWinShotOpensAfterFullScreenExit[screenId] = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + winShotFullScreenExitTimeout, execute: pending.timeout)
        Logger.debug(
            "WinShot: asked full-screen window (CGWindowID \(info.cgWindowId), bundle: \(bundleDesc)) to leave " +
                "full-screen; snapshot \(snapshot.id) opens on \(screenDescription) once it has"
        )
    }

    /// Re-evaluates every waiting arrangement (active Space changes are not attributed to a display).
    internal func attemptPendingWinShotOpensAfterFullScreenExit(reason: String) {
        for screenId in pendingWinShotOpensAfterFullScreenExit.keys {
            attemptPendingWinShotOpenAfterFullScreenExit(on: screenId, reason: reason)
        }
    }

    /// Opens the arrangement waiting for `screenId` once the display has fully left full-screen:
    /// - the pause has cleared (the window's own full-screen state clears early in the exit animation),
    /// - the display no longer shows a full-screen Space (torn down only at the end of the animation;
    ///   a window moved onto the display before that would land in the dying Space), and
    /// - the former full-screen window is back on screen: macOS re-presents it a moment after the
    ///   Space is torn down, reverting what was done to it before then (a minimize issued too early
    ///   is undone).
    ///
    /// Called when the display's pause clears and when the active Space changes; while any signal
    /// is still outstanding (or cannot be read), it re-checks every `winShotFullScreenExitRecheckInterval`
    /// until the wait's timeout.
    internal func attemptPendingWinShotOpenAfterFullScreenExit(on screenId: CGDirectDisplayID, reason: String) {
        guard var pending = pendingWinShotOpensAfterFullScreenExit[screenId] else {
            return
        }
        pending.recheck?.cancel()
        pending.recheck = nil

        let screenDescription = screenContextStore.logDescription(for: screenId)
        if let outstanding = outstandingFullScreenExitSignal(on: screenId, formerFullScreenWindow: pending.fullScreenWindow) {
            if reason != "recheck" {
                Logger.debug("WinShot: \(screenDescription) \(outstanding) (\(reason)); snapshot \(pending.snapshotId) keeps waiting")
            }
            let token = pending.token
            let recheck = DispatchWorkItem { [weak self] in
                guard let self, self.pendingWinShotOpensAfterFullScreenExit[screenId]?.token == token else { return }
                self.attemptPendingWinShotOpenAfterFullScreenExit(on: screenId, reason: "recheck")
            }
            pending.recheck = recheck
            pendingWinShotOpensAfterFullScreenExit[screenId] = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + winShotFullScreenExitRecheckInterval, execute: recheck)
            return
        }

        pending.timeout.cancel()
        pendingWinShotOpensAfterFullScreenExit[screenId] = nil
        guard let snapshot = winShotManager.snapshot(withId: pending.snapshotId) else {
            Logger.debug("WinShot: snapshot \(pending.snapshotId) disappeared while \(screenDescription) left full-screen")
            return
        }
        Logger.debug("WinShot: \(screenDescription) left full-screen (\(reason)); opening snapshot \(snapshot.id)")
        openWinShotSnapshot(snapshot, on: screenId, reason: pending.reason)
    }

    /// Describes what still keeps `screenId` from being ready, or nil once all three signals hold.
    /// An unreadable signal counts as outstanding: acting on a guess would risk the very races the
    /// signals exist to avoid, and the wait is bounded by its timeout.
    private func outstandingFullScreenExitSignal(
        on screenId: CGDirectDisplayID,
        formerFullScreenWindow window: FullScreenElementInfo
    ) -> String? {
        if isScreenPausedForFullScreen(screenId) {
            return "is still paused for full-screen"
        }
        switch SpaceQueries.isDisplayShowingFullScreenSpace(displayId: screenId) {
        case .some(true):
            return "is still showing its full-screen Space"
        case .none:
            return "has no Space information"
        case .some(false):
            break
        }
        guard let onScreen = WindowServerWindowList.onScreenWindowNumbersFrontToBack() else {
            return "has no window list"
        }
        if onScreen.contains(Int(window.cgWindowId)) {
            return nil
        }
        switch WindowServerWindowList.containsWindow(pid: window.pid, cgWindowId: Int(window.cgWindowId)) {
        case .some(false):
            return nil // The former full-screen window is gone; nothing left to re-present.
        case .some(true):
            return "has not re-presented the former full-screen window (CGWindowID \(window.cgWindowId)) yet"
        case .none:
            return "has no window list"
        }
    }

    internal func dropPendingWinShotOpenAfterFullScreenExit(on screenId: CGDirectDisplayID, reason: String) {
        guard let pending = pendingWinShotOpensAfterFullScreenExit.removeValue(forKey: screenId) else {
            return
        }
        pending.timeout.cancel()
        pending.recheck?.cancel()
        Logger.debug(
            "WinShot: dropped snapshot \(pending.snapshotId) waiting for " +
                "\(screenContextStore.logDescription(for: screenId)) to leave full-screen (\(reason))"
        )
    }

    internal func dropAllPendingWinShotOpensAfterFullScreenExit(reason: String) {
        for screenId in pendingWinShotOpensAfterFullScreenExit.keys {
            dropPendingWinShotOpenAfterFullScreenExit(on: screenId, reason: reason)
        }
    }
}
