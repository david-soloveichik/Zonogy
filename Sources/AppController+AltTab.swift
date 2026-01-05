/// AltTab minimized window switcher integration
import AppKit

extension AppController: AltTabControllerDelegate {
    // MARK: - Window Selection

    func altTabController(_ controller: AltTabController, didSelectWindow window: LauncherWindowItem) {
        // Reuse the Launcher's window selection logic
        // Unminimized windows are activated in place; minimized windows go to target zone
        handleWindowSelection(window, activateInPlace: !window.isMinimized)
    }

    // MARK: - Dismissal

    func altTabControllerDidDismiss(_ controller: AltTabController) {
        Logger.debug("AltTab: Dismissed")
        altTabKeyInterceptor.resetEngagement()
    }

    // MARK: - All Managed Windows Provider

    func allManagedWindowsOrderedByRecency() -> [LauncherWindowItem] {
        var items: [LauncherWindowItem] = []

        // Collect all non-placeholder managed windows across all applications
        for window in windowController.allWindows {
            guard !window.isPlaceholder,
                  case .accessibility(let element, let pid, _) = window.backing else {
                continue
            }

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
                isMinimized: window.isMinimized,
                axElement: element,
                lastActiveTime: windowController.lastActiveTime(for: window.windowId),
                bundleIdentifier: bundleId,
                pid: pid,
                managedWindowId: window.windowId
            )
            items.append(item)
        }

        // Sort by lastActiveTime (most recent first), then by Zonogy ID
        items.sort { lhs, rhs in
            switch (lhs.lastActiveTime, rhs.lastActiveTime) {
            case (let lhsTime?, let rhsTime?):
                return lhsTime > rhsTime
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                // Fall back to Zonogy ID (discovery order)
                let lhsId = lhs.managedWindowId ?? Int.max
                let rhsId = rhs.managedWindowId ?? Int.max
                return lhsId < rhsId
            }
        }

        return items
    }
}

extension AppController: AltTabKeyInterceptorDelegate {
    func altTabKeyInterceptorIsAltTabVisible(_ interceptor: AltTabKeyInterceptor) -> Bool {
        altTabController.isActive
    }

    func altTabKeyInterceptorShowAltTab(_ interceptor: AltTabKeyInterceptor, initialDirection: AltTabKeyInterceptor.Direction, mode: AltTabMode) -> Bool {
        // Dismiss Launcher if active to avoid overlapping overlays.
        if launcherController.isActive {
            launcherController.hide()
        }

        let initialSelection: AltTabController.InitialSelection
        switch initialDirection {
        case .next:
            initialSelection = .mostRecent
        case .previous:
            initialSelection = .leastRecent
        }

        switch mode {
        case .allWindows:
            return altTabController.show(initialSelection: initialSelection)
        case .currentAppOnly:
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
                  let bundleId = frontmostApp.bundleIdentifier else {
                // No frontmost app or no bundle identifier - show empty state
                return altTabController.show(initialSelection: initialSelection, appFilter: .noWindows)
            }
            let appName = frontmostApp.localizedName ?? bundleId
            return altTabController.show(initialSelection: initialSelection, appFilter: .app(bundleId: bundleId, name: appName))
        }
    }

    func altTabKeyInterceptor(_ interceptor: AltTabKeyInterceptor, cycle direction: AltTabKeyInterceptor.Direction) {
        switch direction {
        case .next:
            altTabController.selectNext()
        case .previous:
            altTabController.selectPrevious()
        }
    }

    func altTabKeyInterceptorActivateSelection(_ interceptor: AltTabKeyInterceptor) {
        altTabController.activateSelectedWindow()
    }

    func altTabKeyInterceptorCancel(_ interceptor: AltTabKeyInterceptor) {
        altTabController.hide()
    }

    func altTabKeyInterceptorShouldHandleEvents(_ interceptor: AltTabKeyInterceptor) -> Bool {
        !hotkeyService.isSuspended
    }
}
