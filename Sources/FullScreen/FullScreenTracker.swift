/// Tracks which screens have full-screen windows from managed apps using the AXFullScreen attribute.
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
    let windowId: Int
    let cgWindowId: CGWindowID
    let pid: pid_t
    let bundleIdentifier: String?
    let screenDisplayId: CGDirectDisplayID

    static func == (lhs: FullScreenWindowInfo, rhs: FullScreenWindowInfo) -> Bool {
        lhs.windowId == rhs.windowId && lhs.cgWindowId == rhs.cgWindowId
    }
}

/// Delegate notified of full-screen state changes.
protocol FullScreenTrackerDelegate: AnyObject {
    func fullScreenTracker(_ tracker: FullScreenTracker, didChangeFullScreenStateFor displayId: CGDirectDisplayID)
}

/// Tracks screens that have full-screen windows from managed apps using the AXFullScreen attribute.
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
        guard status == .success else {
            return false
        }
        guard CFGetTypeID(value!) == CFBooleanGetTypeID() else {
            return false
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// Handle a window entering or exiting full-screen mode.
    /// Called when a resize notification is received for a managed window.
    /// - Parameters:
    ///   - windowId: The Zonogy window ID
    ///   - cgWindowId: The CGWindowID
    ///   - element: The accessibility element
    ///   - pid: The process identifier
    ///   - bundleIdentifier: The app's bundle identifier
    ///   - screenDisplayId: The display ID where the window is located
    func handleWindowFullScreenStateChange(
        windowId: Int,
        cgWindowId: CGWindowID,
        element: AXUIElement,
        pid: pid_t,
        bundleIdentifier: String?,
        screenDisplayId: CGDirectDisplayID
    ) {
        let isFullScreen = FullScreenTracker.isWindowFullScreen(element: element)
        let wasFullScreen = fullScreenWindows.values.contains { $0.windowId == windowId }

        if isFullScreen && !wasFullScreen {
            // Window entered full-screen
            let info = FullScreenWindowInfo(
                windowId: windowId,
                cgWindowId: cgWindowId,
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                screenDisplayId: screenDisplayId
            )

            // Remove any existing full-screen window on this display
            if let existing = fullScreenWindows[screenDisplayId], existing.windowId != windowId {
                let screenIndex = ScreenContextStore.loggingIndex(for: screenDisplayId)
                Logger.debug("FullScreenTracker: replacing full-screen window \(existing.windowId) with \(windowId) on screen \(screenIndex)")
            }

            fullScreenWindows[screenDisplayId] = info
            let screenIndex = ScreenContextStore.loggingIndex(for: screenDisplayId)
            Logger.debug("FullScreenTracker: window \(windowId) (CGWindowID \(cgWindowId), bundle: \(bundleIdentifier ?? "unknown")) entered full-screen on screen \(screenIndex)")
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: screenDisplayId)

        } else if !isFullScreen && wasFullScreen {
            // Window exited full-screen - find which display it was on
            for (displayId, info) in fullScreenWindows where info.windowId == windowId {
                fullScreenWindows.removeValue(forKey: displayId)
                let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
                Logger.debug("FullScreenTracker: window \(windowId) (CGWindowID \(cgWindowId), bundle: \(bundleIdentifier ?? "unknown")) exited full-screen on screen \(screenIndex)")
                delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
                break
            }
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
                let bundleDesc = info.bundleIdentifier ?? "unknown"
                Logger.debug("FullScreenTracker: app pid \(pid) (bundle: \(bundleDesc), window \(info.windowId)) terminated, screen \(screenIndex) exiting full-screen mode")
            }
        }
        for displayId in changedDisplayIds {
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
        }
    }

    /// Update full-screen state when a specific window closes.
    func windowDidClose(windowId: Int) {
        for (displayId, info) in fullScreenWindows where info.windowId == windowId {
            fullScreenWindows.removeValue(forKey: displayId)
            let screenIndex = ScreenContextStore.loggingIndex(for: displayId)
            let bundleDesc = info.bundleIdentifier ?? "unknown"
            Logger.debug("FullScreenTracker: full-screen window \(windowId) (bundle: \(bundleDesc)) closed, screen \(screenIndex) exiting full-screen mode")
            delegate?.fullScreenTracker(self, didChangeFullScreenStateFor: displayId)
            return // A window can only be full-screen on one display
        }
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
}
