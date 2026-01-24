/// Tracks which screens have full-screen windows from eligible apps using the AXFullScreen attribute.
///
/// Detection approach:
/// 1. Query the `AXFullScreen` attribute via Accessibility API
/// 2. Listen to `kAXResizedNotification` which fires when windows enter/exit full-screen
import AppKit
import ApplicationServices

/// The private AXFullScreen attribute used to detect native macOS full-screen mode.
private let kAXFullscreenAttribute = "AXFullScreen" as CFString

/// Information about a full-screen window on a display.
struct FullScreenWindowInfo: Equatable {
    let windowId: Int?
    let cgWindowId: CGWindowID
    let pid: pid_t
    let bundleIdentifier: String?
    let screenDisplayId: CGDirectDisplayID

    static func == (lhs: FullScreenWindowInfo, rhs: FullScreenWindowInfo) -> Bool {
        lhs.cgWindowId == rhs.cgWindowId && lhs.pid == rhs.pid
    }
}

/// Delegate notified of full-screen state changes.
protocol FullScreenTrackerDelegate: AnyObject {
    func fullScreenTracker(_ tracker: FullScreenTracker, didChangeFullScreenStateFor displayId: CGDirectDisplayID)
}

/// Tracks screens that have full-screen windows from eligible apps using the AXFullScreen attribute.
final class FullScreenTracker {
    weak var delegate: FullScreenTrackerDelegate?

    /// Maps display IDs to the window causing full-screen mode on that display.
    private(set) var fullScreenWindows: [CGDirectDisplayID: FullScreenWindowInfo] = [:]

    /// Screens currently in full-screen mode.
    var fullScreenDisplayIds: Set<CGDirectDisplayID> {
        Set(fullScreenWindows.keys)
    }

    init() {}

    /// Check if a specific screen is in full-screen mode.
    func isFullScreen(displayId: CGDirectDisplayID) -> Bool {
        fullScreenWindows[displayId] != nil
    }

    /// Get the window info causing full-screen mode on a display.
    func fullScreenWindowInfo(for displayId: CGDirectDisplayID) -> FullScreenWindowInfo? {
        fullScreenWindows[displayId]
    }

    // MARK: - Full-Screen State Detection

    /// Check if a window is in full-screen mode by querying the AXFullScreen attribute.
    static func isWindowFullScreen(element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXFullscreenAttribute, &value)
        guard status == .success, let value else {
            return false
        }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return false
        }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    /// Handle a window entering or exiting full-screen mode.
    /// Called when a resize notification is received for an observed window.
    /// - Parameters:
    ///   - windowId: The Zonogy window ID (if managed)
    ///   - cgWindowId: The CGWindowID
    ///   - element: The accessibility element
    ///   - pid: The process identifier
    ///   - bundleIdentifier: The app's bundle identifier
    ///   - screenDisplayId: The display ID where the window is located
    func handleWindowFullScreenStateChange(
        windowId: Int?,
        cgWindowId: CGWindowID,
        element: AXUIElement,
        pid: pid_t,
        bundleIdentifier: String?,
        screenDisplayId: CGDirectDisplayID
    ) {
        let isFullScreen = FullScreenTracker.isWindowFullScreen(element: element)
        let existingEntry = trackedEntry(for: cgWindowId, pid: pid)
        let existingInfo = existingEntry?.info
        let wasFullScreen = existingInfo != nil

        if isFullScreen {
            let resolvedWindowId = windowId ?? existingInfo?.windowId
            let resolvedBundleId = bundleIdentifier ?? existingInfo?.bundleIdentifier
            let info = FullScreenWindowInfo(
                windowId: resolvedWindowId,
                cgWindowId: cgWindowId,
                pid: pid,
                bundleIdentifier: resolvedBundleId,
                screenDisplayId: screenDisplayId
            )

            if let existingEntry {
                let oldDisplayId = existingEntry.displayId
                if oldDisplayId != screenDisplayId {
                    fullScreenWindows.removeValue(forKey: oldDisplayId)
                    let oldScreenIndex = ScreenContextStore.loggingIndex(for: oldDisplayId)
                    let newScreenIndex = ScreenContextStore.loggingIndex(for: screenDisplayId)
                    Logger.debug("FullScreenTracker: \(windowDescriptor(info)) moved full-screen from screen \(oldScreenIndex) to screen \(newScreenIndex)")
                    delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: oldDisplayId)
                }

                if let existingOnDisplay = fullScreenWindows[screenDisplayId],
                   existingOnDisplay.cgWindowId != cgWindowId || existingOnDisplay.pid != pid {
                    let screenIndex = ScreenContextStore.loggingIndex(for: screenDisplayId)
                    Logger.debug("FullScreenTracker: replacing full-screen window \(windowDescriptor(existingOnDisplay)) with \(windowDescriptor(info)) on screen \(screenIndex)")
                }

                fullScreenWindows[screenDisplayId] = info
                if oldDisplayId != screenDisplayId {
                    delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: screenDisplayId)
                }
            } else {
                if let existingOnDisplay = fullScreenWindows[screenDisplayId],
                   existingOnDisplay.cgWindowId != cgWindowId || existingOnDisplay.pid != pid {
                    let screenIndex = ScreenContextStore.loggingIndex(for: screenDisplayId)
                    Logger.debug("FullScreenTracker: replacing full-screen window \(windowDescriptor(existingOnDisplay)) with \(windowDescriptor(info)) on screen \(screenIndex)")
                }

                fullScreenWindows[screenDisplayId] = info
                let screenIndex = ScreenContextStore.loggingIndex(for: screenDisplayId)
                Logger.debug("FullScreenTracker: \(windowDescriptor(info)) entered full-screen on screen \(screenIndex)")
                delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: screenDisplayId)
            }
        } else if !isFullScreen && wasFullScreen, let existingEntry {
            fullScreenWindows.removeValue(forKey: existingEntry.displayId)
            let screenIndex = ScreenContextStore.loggingIndex(for: existingEntry.displayId)
            Logger.debug("FullScreenTracker: \(windowDescriptor(existingEntry.info)) exited full-screen on screen \(screenIndex)")
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: existingEntry.displayId)
        }
    }

    /// Update full-screen state when an app terminates.
    func applicationDidTerminate(pid: pid_t) {
        var changedDisplayIds: [CGDirectDisplayID] = []
        for (displayId, info) in fullScreenWindows {
            if info.pid == pid {
                fullScreenWindows.removeValue(forKey: displayId)
                changedDisplayIds.append(displayId)
                let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                Logger.debug("FullScreenTracker: app pid \(pid) (\(windowDescriptor(info))) terminated, screen \(screenIndex) exiting full-screen mode")
            }
        }
        for displayId in changedDisplayIds {
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
        }
    }

    /// Update full-screen state when a specific window closes (managed).
    func windowDidClose(windowId: Int) {
        for (displayId, info) in fullScreenWindows where info.windowId == windowId {
            fullScreenWindows.removeValue(forKey: displayId)
            let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
            Logger.debug("FullScreenTracker: full-screen window \(windowDescriptor(info)) closed, screen \(screenIndex) exiting full-screen mode")
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
            return // A window can only be full-screen on one display
        }
    }

    /// Update full-screen state when a specific window closes (managed or unmanaged).
    func windowDidClose(cgWindowId: CGWindowID, pid: pid_t) {
        guard let existingEntry = trackedEntry(for: cgWindowId, pid: pid) else {
            return
        }
        fullScreenWindows.removeValue(forKey: existingEntry.displayId)
        let screenIndex = ScreenContextStore.loggingIndex(for: existingEntry.displayId)
        Logger.debug("FullScreenTracker: full-screen window \(windowDescriptor(existingEntry.info)) closed, screen \(screenIndex) exiting full-screen mode")
        delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: existingEntry.displayId)
    }

    /// Clear all full-screen tracking state.
    /// Called during sleep/wake or display reconfiguration.
    func clearAllState() {
        let displayIds = Array(fullScreenWindows.keys)
        fullScreenWindows.removeAll()
        for displayId in displayIds {
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
        }
    }

    private func trackedEntry(for cgWindowId: CGWindowID, pid: pid_t) -> (displayId: CGDirectDisplayID, info: FullScreenWindowInfo)? {
        for (displayId, info) in fullScreenWindows where info.cgWindowId == cgWindowId && info.pid == pid {
            return (displayId, info)
        }
        return nil
    }

    private func windowDescriptor(_ info: FullScreenWindowInfo) -> String {
        let windowIdDesc = info.windowId.map(String.init) ?? "n/a"
        let bundleDesc = info.bundleIdentifier ?? "unknown"
        return "windowId \(windowIdDesc) (CGWindowID \(info.cgWindowId), bundle: \(bundleDesc))"
    }
}
