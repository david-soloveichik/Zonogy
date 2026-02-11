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
            Logger.debug("\(prefix)pid \(pid) has no tracked focused window (or focused window is unavailable)")
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

    internal enum UnmanagedFocusResolution {
        case managed
        case unmanaged(screenId: CGDirectDisplayID, reason: String)
        case unresolved(pid: pid_t, reason: String)
    }

    /// Resolves whether frontmost focus is managed, confirmed unmanaged, or unresolved.
    /// Unmanaged focus requires positive confirmation; transient AX failures stay unresolved.
    internal func resolveUnmanagedFocusState() -> UnmanagedFocusResolution {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return .managed
        }

        let pid = frontmostApp.processIdentifier
        guard pid != getpid() else {
            return .managed
        }

        let appElement = windowController.accessibilityWatcher.applicationElement(for: pid)
        var windowObject: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowObject)
        guard focusedWindowResult == .success,
              let windowObject,
              CFGetTypeID(windowObject) == AXUIElementGetTypeID() else {
            return .unresolved(pid: pid, reason: "focused-window-\(focusedWindowResult.logDescription)")
        }
        let focusedWindow = unsafeBitCast(windowObject, to: AXUIElement.self)

        if let tracked = windowController.managedWindow(matching: focusedWindow),
           tracked.zoneIndex != nil || isWindowInTemporaryZone(tracked.windowId) {
            return .managed
        }

        if let bundleId = frontmostApp.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            guard let screenId = screenId(forWindowElement: focusedWindow) else {
                return .unresolved(pid: pid, reason: "ignored-bundle-screen-unavailable")
            }
            return .unmanaged(screenId: screenId, reason: "ignored-bundle")
        }

        guard let externalIdentifier = windowController.externalIdentifier(for: focusedWindow) else {
            return .unresolved(pid: pid, reason: "missing-cgwindowid")
        }

        let isMinimized = windowController.isWindowMinimized(focusedWindow)
        let passesNonWindowIdCriteria = windowController.isStandardWindow(
            focusedWindow,
            pid: pid,
            cgWindowId: CGWindowID(externalIdentifier.cgWindowId),
            skipSubroleCheck: isMinimized
        )

        guard !passesNonWindowIdCriteria else {
            return .unresolved(pid: pid, reason: "window-appears-manageable")
        }

        guard let screenId = screenId(forWindowElement: focusedWindow) else {
            return .unresolved(pid: pid, reason: "unmanaged-screen-unavailable")
        }

        return .unmanaged(screenId: screenId, reason: "fails-non-windowid-management-criteria")
    }

    private func screenId(forWindowElement windowElement: AXUIElement) -> CGDirectDisplayID? {
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
