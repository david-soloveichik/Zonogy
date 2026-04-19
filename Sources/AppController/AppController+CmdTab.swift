/// CmdTab minimized window switcher integration
import AppKit

extension AppController: CmdTabControllerDelegate {
    func cmdTabController(_ controller: CmdTabController, didDismiss outcome: CmdTabController.DismissalOutcome) {
        cmdTabKeyInterceptor.resetEngagement()

        switch outcome {
        case .cancelled:
            Logger.debug("CmdTab: Cancelled")
            restoreCmdTabOriginalTargetIfNeeded(reason: "cmdtab-cancelled")
        case .selected(let window):
            let policyOutcome: CmdTabTemporaryTargetPolicy.Outcome = window.isPlacedInZone
                ? .activatedExistingWindow
                : .placedOrOpenedWindow

            if CmdTabTemporaryTargetPolicy.shouldRestoreOriginalTarget(after: policyOutcome) {
                restoreCmdTabOriginalTargetIfNeeded(reason: "cmdtab-restore-existing-window")
            } else {
                cmdTabRetargetSession = nil
            }

            Logger.debug("CmdTab: Selected \(window.title)")
            // Reuse the Launcher's window selection logic.
            handleWindowSelection(window, activateInPlace: window.isPlacedInZone)
        case .interrupted:
            Logger.debug("CmdTab: Interrupted")
            cmdTabRetargetSession = nil
        }
    }

    // MARK: - All Managed Windows Provider

    func frontmostManagedWindowId() -> Int? {
        currentFrontmostManagedWindowId
    }

    func allManagedWindowsOrderedByRecency() -> [LauncherWindowItem] {
        var items: [LauncherWindowItem] = []

        // Collect all managed windows across all applications in shared recency order.
        for window in windowController.allWindowsOrderedByRecency() {
            let element = window.backing.element
            let pid = window.backing.pid

            // Get title from AX
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            var title = (titleRef as? String) ?? ""
            guard !title.isEmpty else { continue }

            // Get bundle identifier
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleId = app?.bundleIdentifier

            // Strip app name suffix (same logic as Launcher)
            if let appName = app?.localizedName {
                for separator in [" - ", " – ", " — ", " | "] {
                    let suffix = separator + appName
                    if title.hasSuffix(suffix) {
                        title = String(title.dropLast(suffix.count))
                        break
                    }
                }
            }

            let item = LauncherWindowItem(
                title: title,
                isPlacedInZone: window.isPlacedInZone,
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
    func cmdTabKeyInterceptorIsCmdTabVisible(_ interceptor: CmdTabKeyInterceptor) -> Bool {
        cmdTabController.isActive
    }

    func cmdTabKeyInterceptorShowCmdTab(_ interceptor: CmdTabKeyInterceptor, initialDirection: CmdTabKeyInterceptor.Direction, mode: CmdTabMode) -> Bool {
        // Resolve temporary retargeting before hiding Launcher. While Launcher is visible, it is
        // already anchored to the current target, so that target should remain authoritative.
        beginCmdTabRetargetSessionIfNeeded(reason: "cmdtab-open")

        // Dismiss Launcher if active to avoid overlapping overlays.
        if launcherController.isActive {
            launcherController.hide()
        }

        let initialSelection: CmdTabController.InitialSelection
        switch initialDirection {
        case .next:
            initialSelection = .mostRecent
        case .previous:
            initialSelection = .leastRecent
        }

        let shown: Bool
        switch mode {
        case .allWindows:
            shown = cmdTabController.show(initialSelection: initialSelection)
        case .currentAppOnly:
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
                  let bundleId = frontmostApp.bundleIdentifier else {
                // No frontmost app or no bundle identifier - show empty state
                shown = cmdTabController.show(initialSelection: initialSelection, appFilter: .noWindows)
                break
            }
            let appName = frontmostApp.localizedName ?? bundleId
            shown = cmdTabController.show(initialSelection: initialSelection, appFilter: .app(bundleId: bundleId, name: appName))
        }

        if !shown {
            restoreCmdTabOriginalTargetIfNeeded(reason: "cmdtab-open-failed")
        }
        return shown
    }

    func cmdTabKeyInterceptorSwitchMode(_ interceptor: CmdTabKeyInterceptor, mode: CmdTabMode) {
        Logger.debug("CmdTab: Switching to \(mode == .allWindows ? "all windows" : "current app") mode")
        switch mode {
        case .allWindows:
            cmdTabController.show(initialSelection: .mostRecent)
        case .currentAppOnly:
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
                  let bundleId = frontmostApp.bundleIdentifier else {
                cmdTabController.show(initialSelection: .mostRecent, appFilter: .noWindows)
                return
            }
            let appName = frontmostApp.localizedName ?? bundleId
            cmdTabController.show(initialSelection: .mostRecent, appFilter: .app(bundleId: bundleId, name: appName))
        }
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

    func cmdTabKeyInterceptorShouldHandleEvents(_ interceptor: CmdTabKeyInterceptor) -> Bool {
        !hotkeyService.isSuspended
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
        guard let effectiveDestination else {
            cmdTabController.hideForExternalInterruption()
            Logger.debug("CmdTab: Hidden because target cleared")
            return
        }

        if let screenId = screenId(for: effectiveDestination),
           isScreenPausedForFullScreen(screenId) {
            cmdTabController.hideForExternalInterruption()
            Logger.debug("CmdTab: Hidden because target screen is full-screen")
            return
        }

        cmdTabController.repositionToCurrentTarget()
        Logger.debug("CmdTab: Repositioned after target change")
    }
}

private extension AppController {
    func beginCmdTabRetargetSessionIfNeeded(reason: String) {
        cmdTabRetargetSession = nil

        guard cmdTabTargetsZoneWithActiveWindowEnabled,
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
