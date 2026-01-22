/// Tracks which screens have full-screen windows from managed apps.
///
/// A screen is considered in full-screen mode when it has a window that:
/// 1. Spans the full width of the screen
/// 2. Has isMovable = false (position is not settable via accessibility)
/// 3. Belongs to an app that would otherwise be managed by Zonogy
import AppKit
import ApplicationServices

/// Information about a full-screen window on a display.
struct FullScreenWindowInfo: Equatable {
    let element: AXUIElement
    let cgWindowId: CGWindowID
    let pid: pid_t
    let bundleIdentifier: String?

    static func == (lhs: FullScreenWindowInfo, rhs: FullScreenWindowInfo) -> Bool {
        lhs.cgWindowId == rhs.cgWindowId && lhs.pid == rhs.pid
    }
}

/// Delegate notified of full-screen state changes.
protocol FullScreenTrackerDelegate: AnyObject {
    func fullScreenTracker(_ tracker: FullScreenTracker, didChangeFullScreenStateFor displayId: CGDirectDisplayID)
    func fullScreenTracker(_ tracker: FullScreenTracker, didStartTrackingFullScreenWindow info: FullScreenWindowInfo)
    func fullScreenTracker(_ tracker: FullScreenTracker, didStopTrackingFullScreenWindow info: FullScreenWindowInfo)
}

/// Tracks screens that have full-screen windows from managed apps.
final class FullScreenTracker {
    weak var delegate: FullScreenTrackerDelegate?

    private let primaryScreenBounds: CGRect
    private let shouldManageApp: (NSRunningApplication) -> Bool
    private let ignoredBundleIdentifiers: Set<String>

    /// Maps display IDs to the window causing full-screen mode on that display.
    private(set) var fullScreenWindows: [CGDirectDisplayID: FullScreenWindowInfo] = [:]

    /// Screens currently in full-screen mode.
    var fullScreenDisplayIds: Set<CGDirectDisplayID> {
        Set(fullScreenWindows.keys)
    }

    init(
        primaryScreenBounds: CGRect,
        ignoredBundleIdentifiers: Set<String>,
        shouldManageApp: @escaping (NSRunningApplication) -> Bool
    ) {
        self.primaryScreenBounds = primaryScreenBounds
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        self.shouldManageApp = shouldManageApp
    }

    /// Check if a specific screen is in full-screen mode.
    func isFullScreen(displayId: CGDirectDisplayID) -> Bool {
        fullScreenWindows[displayId] != nil
    }

    /// Get the window info causing full-screen mode on a display.
    func fullScreenWindowInfo(for displayId: CGDirectDisplayID) -> FullScreenWindowInfo? {
        fullScreenWindows[displayId]
    }

    /// Update full-screen state for all screens.
    /// Call this during startup and after display configuration changes.
    func updateAllScreens(screenContexts: [CGDirectDisplayID: ScreenContext]) {
        let newState = detectFullScreenWindows(screenContexts: screenContexts)
        applyStateChanges(newState: newState)
    }

    /// Update full-screen state when an app terminates.
    func applicationDidTerminate(pid: pid_t) {
        var changedEntries: [(displayId: CGDirectDisplayID, info: FullScreenWindowInfo)] = []
        for (displayId, info) in fullScreenWindows {
            if info.pid == pid {
                fullScreenWindows.removeValue(forKey: displayId)
                changedEntries.append((displayId, info))
            }
        }
        for entry in changedEntries {
            let screenIndex = ScreenContextStore.loggingIndex(for: entry.displayId)
            let bundleDesc = entry.info.bundleIdentifier ?? "unknown"
            Logger.debug("FullScreenTracker: app pid \(pid) (bundle: \(bundleDesc), window \(entry.info.cgWindowId)) terminated, screen \(screenIndex) exiting full-screen mode")
            delegate?.fullScreenTracker(self, didStopTrackingFullScreenWindow: entry.info)
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: entry.displayId)
        }
    }

    /// Update full-screen state when a specific window closes.
    /// This is a direct lookup - O(number of displays) - avoiding window server queries.
    func windowDidClose(cgWindowId: CGWindowID) {
        for (displayId, info) in fullScreenWindows where info.cgWindowId == cgWindowId {
            fullScreenWindows.removeValue(forKey: displayId)
            let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
            let bundleDesc = info.bundleIdentifier ?? "unknown"
            Logger.debug("FullScreenTracker: full-screen window \(cgWindowId) (bundle: \(bundleDesc)) closed, screen \(screenIndex) exiting full-screen mode")
            delegate?.fullScreenTracker(self, didStopTrackingFullScreenWindow: info)
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
            return // A window can only be full-screen on one display
        }
    }

    /// Check if a specific non-movable window is a full-screen window.
    /// Called when capture rejects a window due to non-movability.
    /// Takes the window's element and frame directly - no CGWindowList query needed.
    func checkNonMovableWindow(
        element: AXUIElement,
        pid: pid_t,
        cgWindowId: CGWindowID,
        frame: CGRect,
        screenContexts: [CGDirectDisplayID: ScreenContext]
    ) {
        // Check app eligibility
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleId = app.bundleIdentifier,
              !ignoredBundleIdentifiers.contains(bundleId),
              shouldManageApp(app) else {
            return
        }

        // Check which screen this window spans
        for (displayId, context) in screenContexts {
            // Skip if this display already has a full-screen window
            if fullScreenWindows[displayId] != nil { continue }

            let cocoaBounds = context.descriptor.cocoaBounds
            let screenBounds = CoordinateConversion.cocoaToAccessibility(
                cocoaFrame: cocoaBounds,
                primaryScreenBounds: primaryScreenBounds
            )

            let spansFullWidth = frame.minX <= screenBounds.minX &&
                                 frame.maxX >= screenBounds.maxX
            let isOnScreen = frame.intersects(screenBounds)

            if spansFullWidth && isOnScreen {
                let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                Logger.debug("FullScreenTracker: pid \(pid) (bundle: \(bundleId)) entered full-screen on screen \(screenIndex) (window \(cgWindowId))")
                let info = FullScreenWindowInfo(
                    element: element,
                    cgWindowId: cgWindowId,
                    pid: pid,
                    bundleIdentifier: bundleId
                )
                fullScreenWindows[displayId] = info
                delegate?.fullScreenTracker(self, didStartTrackingFullScreenWindow: info)
                delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
                return // Found a full-screen window
            }
        }
    }

    // MARK: - Private

    private func detectFullScreenWindows(screenContexts: [CGDirectDisplayID: ScreenContext]) -> [CGDirectDisplayID: FullScreenWindowInfo] {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        // Build screen bounds map in CG/accessibility coordinates
        var screenBoundsMap: [CGDirectDisplayID: CGRect] = [:]
        for (displayId, context) in screenContexts {
            let cocoaBounds = context.descriptor.cocoaBounds
            let cgBounds = CoordinateConversion.cocoaToAccessibility(
                cocoaFrame: cocoaBounds,
                primaryScreenBounds: primaryScreenBounds
            )
            screenBoundsMap[displayId] = cgBounds
        }

        var result: [CGDirectDisplayID: FullScreenWindowInfo] = [:]

        for windowInfo in windowInfoList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: boundsDict),
                  cgFrame.width > 0 && cgFrame.height > 0 else {
                continue
            }

            guard let ownerPid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let cgWindowId = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            // Skip system windows
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String
            if ownerName == "Finder" || ownerName == "Window Server" || ownerName == "Dock" {
                continue
            }

            // Check if this is from a managed app
            guard let app = NSRunningApplication(processIdentifier: ownerPid),
                  let bundleId = app.bundleIdentifier,
                  !ignoredBundleIdentifiers.contains(bundleId),
                  shouldManageApp(app) else {
                continue
            }

            // Check which screen this window spans
            for (displayId, screenBounds) in screenBoundsMap {
                if result[displayId] != nil { continue }

                let spansFullWidth = cgFrame.minX <= screenBounds.minX &&
                                     cgFrame.maxX >= screenBounds.maxX
                let isOnScreen = cgFrame.intersects(screenBounds)

                if spansFullWidth && isOnScreen {
                    // Check if window is not movable (isMovable = false)
                    let (isMovable, element) = checkWindowMovability(pid: ownerPid, cgWindowId: cgWindowId)
                    if !isMovable, let element {
                        let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                        Logger.debug("FullScreenTracker: detected full-screen window \(cgWindowId) (app: '\(ownerName ?? "unknown")') on screen \(screenIndex)")
                        result[displayId] = FullScreenWindowInfo(
                            element: element,
                            cgWindowId: cgWindowId,
                            pid: ownerPid,
                            bundleIdentifier: bundleId
                        )
                    }
                }
            }

            // Early exit if all screens have full-screen windows
            if result.count == screenBoundsMap.count {
                break
            }
        }

        return result
    }

    /// Check if a window is movable using the Accessibility API.
    /// Returns isMovable and the element if found.
    private func checkWindowMovability(pid: pid_t, cgWindowId: CGWindowID) -> (isMovable: Bool, element: AXUIElement?) {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windows = windowsRef as? [AXUIElement] else {
            return (true, nil) // Assume movable if we can't check
        }

        for windowElement in windows {
            // Get CGWindowID for this AX window
            var windowId: CGWindowID = 0
            let windowIdStatus = _AXUIElementGetWindow(windowElement, &windowId)
            guard windowIdStatus == .success, windowId == cgWindowId else {
                continue
            }

            // Check if position is settable
            var isPositionSettable: DarwinBoolean = false
            let settableStatus = AXUIElementIsAttributeSettable(
                windowElement,
                kAXPositionAttribute as CFString,
                &isPositionSettable
            )

            if settableStatus == .success {
                return (isPositionSettable.boolValue, windowElement)
            }
            return (true, windowElement) // Assume movable if check fails
        }

        return (true, nil) // Window not found, assume movable
    }

    /// Check if a window is movable (convenience wrapper).
    private func isWindowMovable(pid: pid_t, cgWindowId: CGWindowID) -> Bool {
        checkWindowMovability(pid: pid, cgWindowId: cgWindowId).isMovable
    }

    private func applyStateChanges(newState: [CGDirectDisplayID: FullScreenWindowInfo]) {
        let oldDisplayIds = Set(fullScreenWindows.keys)
        let newDisplayIds = Set(newState.keys)

        // Determine changed displays and track start/stop events
        var changedDisplayIds: Set<CGDirectDisplayID> = []
        var stoppedWindows: [FullScreenWindowInfo] = []
        var startedWindows: [FullScreenWindowInfo] = []

        // Displays that exited full-screen
        for displayId in oldDisplayIds.subtracting(newDisplayIds) {
            changedDisplayIds.insert(displayId)
            let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
            if let oldInfo = fullScreenWindows[displayId] {
                let bundleDesc = oldInfo.bundleIdentifier ?? "unknown"
                Logger.debug("FullScreenTracker: screen \(screenIndex) exited full-screen mode (was window \(oldInfo.cgWindowId), bundle: \(bundleDesc))")
                stoppedWindows.append(oldInfo)
            } else {
                Logger.debug("FullScreenTracker: screen \(screenIndex) exited full-screen mode")
            }
        }

        // Displays that entered full-screen
        for displayId in newDisplayIds.subtracting(oldDisplayIds) {
            changedDisplayIds.insert(displayId)
            let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
            if let newInfo = newState[displayId] {
                let bundleDesc = newInfo.bundleIdentifier ?? "unknown"
                Logger.debug("FullScreenTracker: screen \(screenIndex) entered full-screen mode (window \(newInfo.cgWindowId), bundle: \(bundleDesc))")
                startedWindows.append(newInfo)
            } else {
                Logger.debug("FullScreenTracker: screen \(screenIndex) entered full-screen mode")
            }
        }

        // Displays where the window changed
        for displayId in oldDisplayIds.intersection(newDisplayIds) {
            if fullScreenWindows[displayId] != newState[displayId] {
                changedDisplayIds.insert(displayId)
                let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                let oldInfo = fullScreenWindows[displayId]
                let newInfo = newState[displayId]
                let oldDesc = oldInfo.map { "window \($0.cgWindowId), bundle: \($0.bundleIdentifier ?? "unknown")" } ?? "none"
                let newDesc = newInfo.map { "window \($0.cgWindowId), bundle: \($0.bundleIdentifier ?? "unknown")" } ?? "none"
                Logger.debug("FullScreenTracker: screen \(screenIndex) full-screen window changed from (\(oldDesc)) to (\(newDesc))")
                if let oldInfo { stoppedWindows.append(oldInfo) }
                if let newInfo { startedWindows.append(newInfo) }
            }
        }

        fullScreenWindows = newState

        // Notify about tracking changes
        for info in stoppedWindows {
            delegate?.fullScreenTracker(self, didStopTrackingFullScreenWindow: info)
        }
        for info in startedWindows {
            delegate?.fullScreenTracker(self, didStartTrackingFullScreenWindow: info)
        }
        for displayId in changedDisplayIds {
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
        }
    }
}
