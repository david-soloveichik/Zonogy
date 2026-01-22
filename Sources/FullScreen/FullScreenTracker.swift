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
    let cgWindowId: CGWindowID
    let pid: pid_t
    let bundleIdentifier: String?
}

/// Delegate notified of full-screen state changes.
protocol FullScreenTrackerDelegate: AnyObject {
    func fullScreenTracker(_ tracker: FullScreenTracker, didChangeFullScreenStateFor displayId: CGDirectDisplayID)
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
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: entry.displayId)
        }
    }

    /// Recheck full-screen state for a specific pid.
    /// This is a targeted check that only examines windows from the given pid,
    /// avoiding full enumeration overhead.
    /// Call this when a window from this pid closes (might have entered full-screen)
    /// or when a window from this pid becomes manageable (might have exited full-screen).
    func recheckPid(_ pid: pid_t, screenContexts: [CGDirectDisplayID: ScreenContext]) {
        // Build screen bounds map
        var screenBoundsMap: [CGDirectDisplayID: CGRect] = [:]
        for (displayId, context) in screenContexts {
            let cocoaBounds = context.descriptor.cocoaBounds
            let cgBounds = CoordinateConversion.cocoaToAccessibility(
                cocoaFrame: cocoaBounds,
                primaryScreenBounds: primaryScreenBounds
            )
            screenBoundsMap[displayId] = cgBounds
        }

        // Get current windows for this pid
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            // Can't enumerate - clear any tracked windows for this pid
            clearWindowsForPid(pid)
            return
        }

        // Check app eligibility once
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleId = app.bundleIdentifier,
              !ignoredBundleIdentifiers.contains(bundleId),
              shouldManageApp(app) else {
            // App not eligible - clear any tracked windows
            clearWindowsForPid(pid)
            return
        }

        // Find full-screen windows for this pid
        var newFullScreenForPid: [CGDirectDisplayID: FullScreenWindowInfo] = [:]

        for windowInfo in windowInfoList {
            guard let ownerPid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid == pid else {
                continue
            }

            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: boundsDict),
                  cgFrame.width > 0 && cgFrame.height > 0,
                  let cgWindowId = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String

            // Check which screen this window spans
            for (displayId, screenBounds) in screenBoundsMap {
                if newFullScreenForPid[displayId] != nil { continue }

                let spansFullWidth = cgFrame.minX <= screenBounds.minX &&
                                     cgFrame.maxX >= screenBounds.maxX
                let isOnScreen = cgFrame.intersects(screenBounds)

                if spansFullWidth && isOnScreen {
                    if !isWindowMovable(pid: pid, cgWindowId: cgWindowId) {
                        let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                        Logger.debug("FullScreenTracker: recheckPid detected full-screen window \(cgWindowId) (app: '\(ownerName ?? "unknown")') on screen \(screenIndex)")
                        newFullScreenForPid[displayId] = FullScreenWindowInfo(
                            cgWindowId: cgWindowId,
                            pid: pid,
                            bundleIdentifier: bundleId
                        )
                    }
                }
            }
        }

        // Apply changes for this pid only
        applyPidStateChanges(pid: pid, newStateForPid: newFullScreenForPid)
    }

    // MARK: - Private

    /// Clear all tracked full-screen windows for a specific pid.
    private func clearWindowsForPid(_ pid: pid_t) {
        var changedDisplayIds: [CGDirectDisplayID] = []
        for (displayId, info) in fullScreenWindows {
            if info.pid == pid {
                fullScreenWindows.removeValue(forKey: displayId)
                changedDisplayIds.append(displayId)
                let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                let bundleDesc = info.bundleIdentifier ?? "unknown"
                Logger.debug("FullScreenTracker: cleared full-screen for pid \(pid) (bundle: \(bundleDesc), window \(info.cgWindowId)) on screen \(screenIndex)")
            }
        }
        for displayId in changedDisplayIds {
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
        }
    }

    /// Apply state changes for a specific pid only.
    private func applyPidStateChanges(pid: pid_t, newStateForPid: [CGDirectDisplayID: FullScreenWindowInfo]) {
        var changedDisplayIds: Set<CGDirectDisplayID> = []

        // Find displays where this pid's full-screen state changed
        // First, check displays that had this pid's windows
        for (displayId, info) in fullScreenWindows where info.pid == pid {
            if let newInfo = newStateForPid[displayId] {
                // Window changed on this display
                if info != newInfo {
                    changedDisplayIds.insert(displayId)
                    let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                    Logger.debug("FullScreenTracker: pid \(pid) full-screen window changed on screen \(screenIndex) from \(info.cgWindowId) to \(newInfo.cgWindowId)")
                    fullScreenWindows[displayId] = newInfo
                }
            } else {
                // This pid no longer has a full-screen window on this display
                changedDisplayIds.insert(displayId)
                let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                let bundleDesc = info.bundleIdentifier ?? "unknown"
                Logger.debug("FullScreenTracker: pid \(pid) (bundle: \(bundleDesc)) exited full-screen on screen \(screenIndex)")
                fullScreenWindows.removeValue(forKey: displayId)
            }
        }

        // Check for new full-screen windows from this pid on displays that didn't have one
        for (displayId, newInfo) in newStateForPid {
            if fullScreenWindows[displayId] == nil {
                changedDisplayIds.insert(displayId)
                let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                let bundleDesc = newInfo.bundleIdentifier ?? "unknown"
                Logger.debug("FullScreenTracker: pid \(pid) (bundle: \(bundleDesc)) entered full-screen on screen \(screenIndex) (window \(newInfo.cgWindowId))")
                fullScreenWindows[displayId] = newInfo
            }
            // Note: If another pid already has full-screen on this display, we don't replace it.
            // The first full-screen window detected "wins" for that display.
        }

        for displayId in changedDisplayIds {
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
        }
    }

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
                    if !isWindowMovable(pid: ownerPid, cgWindowId: cgWindowId) {
                        let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                        Logger.debug("FullScreenTracker: detected full-screen window \(cgWindowId) (app: '\(ownerName ?? "unknown")') on screen \(screenIndex)")
                        result[displayId] = FullScreenWindowInfo(
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
    private func isWindowMovable(pid: pid_t, cgWindowId: CGWindowID) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windows = windowsRef as? [AXUIElement] else {
            return true // Assume movable if we can't check
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
                return isPositionSettable.boolValue
            }
            return true // Assume movable if check fails
        }

        return true // Window not found, assume movable
    }

    private func applyStateChanges(newState: [CGDirectDisplayID: FullScreenWindowInfo]) {
        let oldDisplayIds = Set(fullScreenWindows.keys)
        let newDisplayIds = Set(newState.keys)

        // Determine changed displays
        var changedDisplayIds: Set<CGDirectDisplayID> = []

        // Displays that exited full-screen
        for displayId in oldDisplayIds.subtracting(newDisplayIds) {
            changedDisplayIds.insert(displayId)
            let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
            if let oldInfo = fullScreenWindows[displayId] {
                let bundleDesc = oldInfo.bundleIdentifier ?? "unknown"
                Logger.debug("FullScreenTracker: screen \(screenIndex) exited full-screen mode (was window \(oldInfo.cgWindowId), bundle: \(bundleDesc))")
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
            }
        }

        fullScreenWindows = newState

        for displayId in changedDisplayIds {
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
        }
    }
}
