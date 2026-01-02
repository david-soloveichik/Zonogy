import Foundation
import AppKit

/// Shared lookup helpers for retrieving focused managed windows and their zone metadata.
extension AppController {
    /// Returns the currently focused managed window for the frontmost application when it is eligible for automation.
    /// - Parameter logPrefix: Text prepended to debug logs when lookup fails so callers can retain their context.
    internal func managedWindowForFrontmostApplication(
        logPrefix: String = "Managed window lookup failed"
    ) -> (window: ManagedWindow, pid: pid_t)? {
        let prefix = logPrefix.isEmpty ? "" : "\(logPrefix): "

        guard let application = NSWorkspace.shared.frontmostApplication else {
            Logger.debug("\(prefix)unable to determine frontmost application")
            return nil
        }

        let pid = application.processIdentifier
        guard pid != getpid() else {
            Logger.debug("\(prefix)Zonogy is the frontmost application")
            return nil
        }

        guard let managed = windowController.focusedWindowIfTracked(pid: pid) else {
            Logger.debug("\(prefix)pid \(pid) has no tracked focused window")
            return nil
        }

        guard !managed.isPlaceholder else {
            Logger.debug("\(prefix)focused managed window \(managed.windowId) is a placeholder")
            return nil
        }

        return (managed, pid)
    }

    /// Resolves the current zone assignment for a managed window, consulting cached metadata if needed.
    internal func zoneKey(forManagedWindow managed: ManagedWindow) -> ZoneKey? {
        if let screenId = managed.screenDisplayId,
           let index = managed.zoneIndex {
            return ZoneKey(screenId: screenId, index: index)
        }

        for (screenId, context) in screenContexts {
            if let zone = context.zoneController.zoneForWindow(windowId: managed.windowId) {
                return ZoneKey(screenId: screenId, index: zone.index)
            }
        }

        return nil
    }

    /// Picks the lowest-index empty zone on the screen, or the highest-index zone when every zone is occupied.
    internal func preferredZoneKey(on screenId: CGDirectDisplayID) -> ZoneKey? {
        guard let context = screenContexts[screenId] else {
            return nil
        }

        if let emptyZone = context.zoneController.findEmptyZone() {
            return ZoneKey(screenId: screenId, index: emptyZone.index)
        }

        guard let fallbackZone = context.zoneController.highestIndexZone() else {
            return nil
        }

        return ZoneKey(screenId: screenId, index: fallbackZone.index)
    }

    /// Returns the screen ID where an unmanaged window currently has focus.
    /// Returns nil if the focused window is managed (in a tiling zone or temporary zone), or if Zonogy is frontmost.
    internal func screenIdForUnmanagedFocusedWindow() -> CGDirectDisplayID? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let pid = frontmostApp.processIdentifier
        guard pid != getpid() else {
            return nil  // Zonogy is frontmost
        }

        // Check if the focused window is tracked and managed
        if let managed = windowController.focusedWindowIfTracked(pid: pid),
           !managed.isPlaceholder {
            // Window is tracked; check if it's actually managed (has zone assignment or is in temporary zone)
            if managed.zoneIndex != nil || isWindowInTemporaryZone(managed.windowId) {
                return nil  // Managed window - don't hide resize bars
            }
        }

        // The focused window is either untracked or tracked but not managed.
        // Get its frame via accessibility to determine which screen it's on.
        let appElement = windowController.accessibilityWatcher.applicationElement(for: pid)

        var windowObject: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowObject)
        guard result == .success,
              let windowObject,
              CFGetTypeID(windowObject) == AXUIElementGetTypeID() else {
            return nil
        }

        let windowElement = unsafeBitCast(windowObject, to: AXUIElement.self)

        guard let position = ManagedWindow.copyCGPointValue(element: windowElement, attribute: kAXPositionAttribute as CFString),
              let size = ManagedWindow.copyCGSizeValue(element: windowElement, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        let accessibilityFrame = CGRect(origin: position, size: size)
        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: accessibilityFrame,
            primaryScreenBounds: primaryScreenBounds
        )

        return screenIdForCocoaFrame(cocoaFrame)
    }
}
