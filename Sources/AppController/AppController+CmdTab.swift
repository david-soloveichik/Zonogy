/// CmdTab minimized window switcher integration
import AppKit

extension AppController: CmdTabControllerDelegate {
    func cmdTabController(_ controller: CmdTabController, didDismiss outcome: CmdTabController.DismissalOutcome) {
        endCmdTabEngagement()
        cmdTabCurrentAppPid = nil

        switch outcome {
        case .cancelled:
            Logger.debug("CmdTab: Cancelled")
            restoreCmdTabOriginalTargetIfNeeded(reason: "cmdtab-cancelled")
        case .selected(let window):
            Logger.debug("CmdTab: Selected \(window.title)")
            // Reuse the Launcher's window selection logic. What it actually did (activate in
            // place, or place — a window parked behind a full-screen Space is placed like a
            // minimized one) decides whether the tentative target commits or is restored, so
            // classification and action can never disagree. Restoring afterward is safe: an
            // in-place activation never consumes the target.
            // Pass live placement state (the item snapshot reports a parked window as not placed
            // for presentation), so the handler's gate makes the place-vs-activate decision.
            let livePlaced = window.managedWindowId
                .flatMap { windowController.window(withId: $0) }?.isPlacedInZone ?? false
            let action = handleWindowSelection(window, activateInPlace: livePlaced)
            let policyOutcome = CmdTabTemporaryTargetPolicy.outcomeForSelection(action: action)

            if CmdTabTemporaryTargetPolicy.shouldRestoreOriginalTarget(after: policyOutcome) {
                restoreCmdTabOriginalTargetIfNeeded(reason: "cmdtab-restore-existing-window")
            } else {
                cmdTabRetargetSession = nil
            }
        case .interrupted:
            Logger.debug("CmdTab: Interrupted")
            cmdTabRetargetSession = nil
        case .dragResolved:
            Logger.debug("CmdTab: Drag resolved")
            cmdTabRetargetSession = nil
        case .openedNewWindow:
            Logger.debug("CmdTab: Opened new window in current app")
            // Opening a new window commits the open-time retarget (the window lands in the target).
            cmdTabRetargetSession = nil
        }
    }

    // MARK: - Row Drag

    func cmdTabController(_ controller: CmdTabController, beginDragForWindow window: LauncherWindowItem) -> Bool {
        guard beginCursorDrivenWindowDrag(for: window) else {
            return false
        }
        // The CmdTab UI is being torn down; end the key interceptor's session so a later modifier
        // release does not try to activate a window in a destroyed session.
        endCmdTabEngagement()
        Logger.debug("CmdTab: drag began for window \(window.title)")
        return true
    }

    /// Ends the interceptor session whose chooser this was. Scoped to that session: one engaged
    /// since (the tap thread runs ahead of the main queue) is untouched.
    private func endCmdTabEngagement() {
        guard let engagement = cmdTabEngagement else { return }
        cmdTabKeyInterceptor.endEngagement(engagement)
        cmdTabEngagement = nil
    }

    func cmdTabControllerDidUpdateDrag(_ controller: CmdTabController, cursorPointAX: CGPoint?) {
        dragDropCoordinator.updateCursorDrivenDragSession(cursorPointAX: cursorPointAX)
    }

    func cmdTabController(_ controller: CmdTabController, didEndDragForWindow window: LauncherWindowItem, cursorPointAX: CGPoint?) -> Bool {
        Logger.debug("CmdTab: drag ended for window \(window.title)")
        return performCursorDrivenManagedWindowDrop(
            for: window,
            cursorPointAX: cursorPointAX,
            reason: "cmdtab-drag"
        )
    }

    func cmdTabControllerDidCancelDrag(_ controller: CmdTabController) {
        Logger.debug("CmdTab: drag cancelled by user (Escape)")
        dragDropCoordinator.tearDownDragSession()
    }

    func cmdTabCurrentCursorAccessibilityPoint() -> CGPoint? {
        currentCursorAccessibilityPoint()
    }

    func allManagedWindowsOrderedByRecency() -> [LauncherWindowItem] {
        var items: [LauncherWindowItem] = []

        // Collect all managed windows across all applications in shared recency order.
        for window in windowController.allWindowsOrderedByRecency() {
            let element = window.backing.element
            let pid = window.backing.pid

            // Get bundle identifier
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleId = app?.bundleIdentifier

            // Resolve the display title via the shared switcher resolver (same logic as Launcher).
            // Intentionally includes parked (minimized) windows — CmdTab surfaces them so the user
            // can switch to and unminimize them; do NOT gate on `isPlacedInZone`. Empty-title
            // managed windows fall back to the open document filename, then the app name.
            let title = SwitcherWindowTitle.resolve(for: element, appName: app?.localizedName)

            let item = LauncherWindowItem(
                title: title,
                isPlacedInZone: isWindowVisiblyPlaced(window),
                axElement: element,
                lastActiveTime: windowController.lastActiveTime(for: window.windowId),
                bundleIdentifier: bundleId,
                pid: pid,
                managedWindowId: window.windowId
            )
            items.append(item)
        }

        return items
    }
}

extension AppController: CmdTabKeyInterceptorDelegate {
    func cmdTabKeyInterceptorShowCmdTab(_ interceptor: CmdTabKeyInterceptor, engagement: CmdTabKeyInterceptor.Engagement, initialDirection: CmdTabKeyInterceptor.Direction, mode: CmdTabMode) {
        // Modifier release, Escape, and N end the session on the tap side; `didDismiss` ends it
        // when the chooser closes some other way (a row click, a drag, an interruption).
        cmdTabEngagement = engagement

        // Resolve temporary retargeting before hiding Launcher. While Launcher is visible, it is
        // already anchored to the current target, so that target should remain authoritative.
        beginCmdTabRetargetSessionIfNeeded(mode: mode, reason: "cmdtab-open")

        // Dismiss the Launcher and the WinShot chooser if open, to avoid overlapping overlays. (The
        // chooser can still be open here only with customized shortcuts: with the defaults, releasing
        // Control to press Cmd-Tab has already confirmed it.)
        if launcherController.isActive {
            launcherController.hide()
        }
        if winShotChooserController.isActive {
            Logger.debug("CmdTab dismissed WinShot chooser")
            winShotChooserController.hide()
        }

        // Capture the app that is frontmost as the chord is pressed. It is this CmdTab session's
        // single "current app": it filters app-specific mode and receives the Cmd-N "new window"
        // shortcut, so the two can never disagree.
        let currentApp = NSWorkspace.shared.frontmostApplication
        cmdTabCurrentAppPid = currentApp?.processIdentifier

        let initialSelection: CmdTabController.InitialSelection
        switch initialDirection {
        case .next:
            initialSelection = .mostRecent
        case .previous:
            initialSelection = .leastRecent
        }

        let skipWindowIds = cmdTabJustMinimizedSkipWindowIds()
        // Always the cached frontmost id. Right after a minimize the cache can briefly lag
        // (the sibling-focus AX notification may not have been processed yet); at worst the
        // auto-focused sibling — the user's previously active window — receives the initial
        // selection, while the marks still guarantee the dismissed window is never offered.
        // A live kAXFocusedWindow read here was deliberately rejected: synchronous AX calls
        // can block for hundreds of milliseconds (see AXCallTimer) and this is the UI-opening path.
        let frontmostWindowId = currentFrontmostManagedWindowId
        let shown: Bool
        switch mode {
        case .allWindows:
            shown = cmdTabController.show(
                initialSelection: initialSelection,
                skipWindowIds: skipWindowIds,
                frontmostWindowId: frontmostWindowId
            )
        case .currentAppOnly:
            guard let currentApp, let bundleId = currentApp.bundleIdentifier else {
                // No frontmost app or no bundle identifier - show empty state
                shown = cmdTabController.show(initialSelection: initialSelection, appFilter: .noWindows)
                break
            }
            let appName = currentApp.localizedName ?? bundleId
            shown = cmdTabController.show(
                initialSelection: initialSelection,
                appFilter: .app(bundleId: bundleId, name: appName),
                skipWindowIds: skipWindowIds,
                frontmostWindowId: frontmostWindowId
            )
        }

        if !shown {
            restoreCmdTabOriginalTargetIfNeeded(reason: "cmdtab-open-failed")
        }
    }

    func cmdTabKeyInterceptorSwitchMode(_ interceptor: CmdTabKeyInterceptor, mode: CmdTabMode) {
        guard cmdTabController.isActive else { return }
        Logger.debug("CmdTab: Switching to \(mode == .allWindows ? "all windows" : "current app") mode")
        let skipWindowIds = cmdTabJustMinimizedSkipWindowIds()
        let frontmostWindowId = currentFrontmostManagedWindowId
        switch mode {
        case .allWindows:
            cmdTabController.show(
                initialSelection: .mostRecent,
                skipWindowIds: skipWindowIds,
                frontmostWindowId: frontmostWindowId
            )
        case .currentAppOnly:
            // Reuse the session's captured current app so switching modes targets the same app.
            guard let pid = cmdTabCurrentAppPid,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleId = app.bundleIdentifier else {
                cmdTabController.show(initialSelection: .mostRecent, appFilter: .noWindows)
                return
            }
            let appName = app.localizedName ?? bundleId
            cmdTabController.show(
                initialSelection: .mostRecent,
                appFilter: .app(bundleId: bundleId, name: appName),
                skipWindowIds: skipWindowIds,
                frontmostWindowId: frontmostWindowId
            )
        }
    }

    /// Windows the user just minimized, for CmdTab's initial selection to skip. The lifetime
    /// deliberately reuses the WinShot occupancy settle delay: both express how long until the
    /// screen has settled for the user.
    private func cmdTabJustMinimizedSkipWindowIds() -> Set<Int> {
        recentUserMinimizeTracker.activeSkipWindowIds(
            settleDelay: TimeInterval(WinShotPreferencesStore.loadOccupancySettleDelaySeconds())
        )
    }
    func cmdTabKeyInterceptor(_ interceptor: CmdTabKeyInterceptor, cycle direction: CmdTabKeyInterceptor.Direction) {
        switch direction {
        case .next:
            cmdTabController.selectNext()
        case .previous:
            cmdTabController.selectPrevious()
        }
    }

    func cmdTabKeyInterceptorActivateSelection(_ interceptor: CmdTabKeyInterceptor) {
        cmdTabController.activateSelectedWindow()
    }

    func cmdTabKeyInterceptorCancel(_ interceptor: CmdTabKeyInterceptor) {
        cmdTabController.cancel()
    }

    func cmdTabKeyInterceptorForwardNewWindow(_ interceptor: CmdTabKeyInterceptor) {
        guard cmdTabController.isActive else { return }
        // Target this session's captured current app — the same app whose windows app-specific
        // mode shows. The CmdTab panel is non-activating, so that app is still frontmost and can
        // receive the synthesized Cmd-N. Re-validate that it is still alive (and not Zonogy): if it
        // quit mid-session, cancel so the open-time retarget is restored rather than committed.
        guard let pid = cmdTabCurrentAppPid, pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            Logger.debug("CmdTab: New-window request ignored - no live current app to forward Cmd-N to")
            cmdTabController.cancel()
            return
        }
        Logger.debug("CmdTab: Forwarding Cmd-N to current app pid=\(pid)")
        cmdTabController.dismissForNewWindow()
        postCmdN(toPid: pid)
    }
}

extension AppController {
    /// Re-center CmdTab on the new target (tiled or floating, empty or occupied) and dismiss only
    /// if the target screen is full-screen paused. If the user manually retargeted mid-chooser,
    /// `TemporaryRetargetSession.shouldRestoreOriginalTarget(currentTarget:)` naturally skips the
    /// restore on cancel because currentTarget no longer matches the saved temporaryTarget.
    internal func refreshCmdTabForCurrentTargetAfterTopologyChange(
        newDestination: TargetedZoneManager.TargetedDestination? = nil
    ) {
        guard cmdTabController.isActive else {
            return
        }

        let effectiveDestination = newDestination ?? targetedZoneManager.targetedDestination

        // Commit the chooser's retarget on a non-tentative target change (e.g. arrow navigation) by
        // dropping the session; a tentative in-chooser retarget (the toggle) keeps it for rebinding.
        if !isApplyingTentativeChooserRetarget,
           let session = cmdTabRetargetSession,
           effectiveDestination != session.temporaryTarget {
            cmdTabRetargetSession = nil
        }

        guard let effectiveDestination else {
            cmdTabController.hideForExternalInterruption()
            Logger.debug("CmdTab: Hidden because target cleared")
            return
        }

        if isScreenPausedForFullScreen(effectiveDestination.screenId) {
            cmdTabController.hideForExternalInterruption()
            Logger.debug("CmdTab: Hidden because target screen is full-screen")
            return
        }

        cmdTabController.repositionToCurrentTarget()
        Logger.debug("CmdTab: Repositioned after target change")
    }
}

private extension AppController {
    func beginCmdTabRetargetSessionIfNeeded(mode: CmdTabMode, reason: String) {
        cmdTabRetargetSession = nil

        guard cmdTabActiveWindowTargetingMode.appliesRetargeting(in: mode),
              let temporaryTarget = resolvedTriggeredTargetUsingActiveWindow(),
              temporaryTarget != targetedZoneManager.targetedDestination else {
            return
        }

        cmdTabRetargetSession = TemporaryRetargetSession(
            originalTarget: targetedZoneManager.targetedDestination,
            temporaryTarget: temporaryTarget
        )
        applyTargetedDestination(temporaryTarget, reason: reason)
    }

    func restoreCmdTabOriginalTargetIfNeeded(reason: String) {
        guard let session = cmdTabRetargetSession else {
            return
        }

        cmdTabRetargetSession = nil

        guard session.shouldRestoreOriginalTarget(
            currentTarget: targetedZoneManager.targetedDestination
        ) else {
            return
        }

        applyTargetedDestination(session.originalTarget, reason: reason)
    }
}
