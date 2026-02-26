import Foundation
import AppKit
import ApplicationServices

/// Basic window operations: minimize, unminimize, close, show, hide, and visibility checks.
extension WindowController {
    /// Best-effort minimization of all standard windows belonging to other applications.
    func minimizeAllExternalWindows() {
        guard ensureAccessibilityPermissions() else {
            return
        }

        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && app.processIdentifier != getpid() {
            let pid = app.processIdentifier
            if let bundleId = app.bundleIdentifier,
               ignoredBundleIdentifiers.contains(bundleId) {
                Logger.debug("Skipping minimization for ignored bundle \(bundleId)")
                continue
            }
            let appElement = accessibilityWatcher.applicationElement(for: pid)

            var windowsObject: AnyObject?
            let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
            guard status == .success, let windowElements = windowsObject as? [AXUIElement] else {
                continue
            }

            for windowElement in windowElements {
                _ = AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    /// Get a managed window by ID
    func window(withId windowId: Int) -> ManagedWindow? {
        return windowRegistry.window(withId: windowId)
    }

    /// Show a window at the specified frame (frame is in screen-local coordinates)
    func showWindow(_ managedWindow: ManagedWindow, at frame: CGRect, on screen: ScreenDescriptor) {
        cancelAccessibilityFrameRetryIfSuperseded(
            windowId: managedWindow.windowId,
            newTargetScreenFrame: frame,
            reason: "show-window"
        )
        let element = managedWindow.backing.element
        // Accessibility API uses screen coordinates directly
        performProgrammaticUpdate(for: managedWindow.windowId) {
            applyScreenFrameWithBestEffort(
                windowId: managedWindow.windowId,
                element: element,
                targetScreenFrame: frame,
                screen: screen
            )
        }
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Showed window \(managedWindow.windowId) on screen \(screenIndex) at frame \(frame)")
    }

    /// Minimize a window
    func minimizeWindow(_ managedWindow: ManagedWindow) {
        let error = AXUIElementSetAttributeValue(managedWindow.backing.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if error != .success {
            Logger.debug("WARNING: Minimize AX call failed for window \(managedWindow.windowId) (error \(error.rawValue))")
        } else {
            Logger.debug("Minimized window \(managedWindow.windowId)")
        }
    }

    /// Unminimize a window
    /// - Parameters:
    ///   - managedWindow: The window to unminimize
    ///   - synchronous: If false (default), adds a small delay to let any pre-positioning settle before the unminimize animation
    func unminimizeWindow(_ managedWindow: ManagedWindow, synchronous: Bool = false, raise: Bool = true) {
        let element = managedWindow.backing.element
        let windowId = managedWindow.windowId
        let perform = {
            let error = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if error != .success {
                Logger.debug("WARNING: Unminimize AX call failed for window \(windowId) (error \(error.rawValue))")
            } else {
                Logger.debug("Unminimized window \(windowId)")
            }
            if raise {
                _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
        }

        if synchronous {
            perform()
        } else {
            // Small async delay to let pre-positioning settle before unminimize animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                perform()
            }
        }
    }

    /// Close a window
    func closeWindow(_ managedWindow: ManagedWindow) {
        removeAccessibilityTracking(for: managedWindow)
        _ = AXUIElementPerformAction(managedWindow.backing.element, axCloseAction)
        windowRegistry.removeWindow(withId: managedWindow.windowId)
        externalWindows.removeValue(forKey: managedWindow.externalIdentifier)
        Logger.debug("Closed window \(managedWindow.windowId)")
    }

    /// Checks if a managed window is currently visible.
    func isWindowVisible(_ managedWindow: ManagedWindow) -> Bool {
        var hiddenValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(managedWindow.backing.element, kAXHiddenAttribute as CFString, &hiddenValue)
        guard status == .success, let hiddenValue else {
            // If we can't get the attribute, assume it's visible for safety.
            return true
        }
        if CFGetTypeID(hiddenValue) == CFBooleanGetTypeID() {
            return !CFBooleanGetValue(unsafeBitCast(hiddenValue, to: CFBoolean.self))
        }
        if let number = hiddenValue as? NSNumber {
            return !number.boolValue
        }
        return true // Default to visible
    }

    /// Hides a managed window.
    func hideWindow(_ managedWindow: ManagedWindow, reason: HideReason) {
        _ = AXUIElementSetAttributeValue(managedWindow.backing.element, kAXHiddenAttribute as CFString, kCFBooleanTrue)
        let reasonLabel: String
        switch reason {
        case .zoneExcluded: reasonLabel = "zone-excluded"
        case .replacedByOccupant: reasonLabel = "replaced-by-occupant"
        case .inactiveZone: reasonLabel = "inactive-zone"
        }
        Logger.debug("Hidden window \(managedWindow.windowId) (reason: \(reasonLabel))")
    }
}
