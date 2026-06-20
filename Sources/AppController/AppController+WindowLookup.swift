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
        case managed(window: ManagedWindow, pid: pid_t, focusedElement: AXUIElement)
        case managedUnknown
        case unmanaged(screenId: CGDirectDisplayID, pid: pid_t, focusedElement: AXUIElement, reason: String)
        case unresolved(pid: pid_t, focusedElement: AXUIElement?, reason: String)
        /// One of Zonogy's own content windows (currently only Preferences) is focused.
        /// Suppresses resize bars on that screen like unmanaged focus, but carries no AX
        /// element and skips the external-app machinery (full-screen pause repair, retries).
        case ownContentWindow(screenId: CGDirectDisplayID)
    }

    /// Resolves whether frontmost focus is managed, confirmed unmanaged, or unresolved.
    /// Unmanaged focus requires positive confirmation; transient AX failures stay unresolved.
    internal func resolveUnmanagedFocusState() -> UnmanagedFocusResolution {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return .managedUnknown
        }

        let pid = frontmostApp.processIdentifier
        guard pid != getpid() else {
            return resolveOwnAppFocusState()
        }

        let appElement = windowController.accessibilityWatcher.applicationElement(for: pid)
        var windowObject: CFTypeRef?
        let focusedWindowResult = AXCall.copyAttribute(appElement, kAXFocusedWindowAttribute as CFString, &windowObject)
        guard focusedWindowResult == .success,
              let windowObject,
              CFGetTypeID(windowObject) == AXUIElementGetTypeID() else {
            return .unresolved(pid: pid, focusedElement: nil, reason: "focused-window-\(focusedWindowResult.logDescription)")
        }
        let focusedWindow = unsafeBitCast(windowObject, to: AXUIElement.self)

        if let tracked = windowController.managedWindow(matching: focusedWindow),
           tracked.zoneIndex != nil || isWindowInFloatingZone(tracked.windowId) {
            return .managed(window: tracked, pid: pid, focusedElement: focusedWindow)
        }

        if let bundleId = frontmostApp.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            guard let screenId = screenId(forWindowElement: focusedWindow) else {
                return .unresolved(pid: pid, focusedElement: focusedWindow, reason: "ignored-bundle-screen-unavailable")
            }
            return .unmanaged(screenId: screenId, pid: pid, focusedElement: focusedWindow, reason: "ignored-bundle")
        }

        guard let externalIdentifier = windowController.externalIdentifier(for: focusedWindow) else {
            return .unresolved(pid: pid, focusedElement: focusedWindow, reason: "missing-cgwindowid")
        }

        let isMinimized = windowController.isWindowMinimized(focusedWindow)
        let passesNonWindowIdCriteria = windowController.isStandardWindow(
            focusedWindow,
            pid: pid,
            cgWindowId: CGWindowID(externalIdentifier.cgWindowId),
            skipSubroleCheck: isMinimized
        )

        guard !passesNonWindowIdCriteria else {
            return .unresolved(pid: pid, focusedElement: focusedWindow, reason: "window-appears-manageable")
        }

        guard let screenId = screenId(forWindowElement: focusedWindow) else {
            return .unresolved(pid: pid, focusedElement: focusedWindow, reason: "unmanaged-screen-unavailable")
        }

        return .unmanaged(
            screenId: screenId,
            pid: pid,
            focusedElement: focusedWindow,
            reason: "fails-non-windowid-management-criteria"
        )
    }

    /// When Zonogy itself is frontmost, only its Preferences window suppresses zone resize bars.
    /// Every other Zonogy-owned window (Launcher, placeholders, indicators, the resize bars
    /// themselves, etc.) leaves the bars unaffected. Resolved synchronously from AppKit — no AX
    /// round trip and no retry confirmation needed.
    private func resolveOwnAppFocusState() -> UnmanagedFocusResolution {
        guard let preferencesWindow = focusedPreferencesWindow(),
              let screen = preferencesWindow.screen,
              let screenId = ScreenContextStore.displayId(for: screen) else {
            return .managedUnknown
        }
        return .ownContentWindow(screenId: screenId)
    }

    /// The Preferences window if it is currently Zonogy's focused content window, else nil.
    /// Preferences counts as focused when it — or one of its sheets (Add App, edit rule,
    /// open/save panels) — holds key. Other Zonogy panels that can take key without becoming
    /// main (Launcher, CmdTab) deliberately do not qualify, even when shown over Preferences.
    private func focusedPreferencesWindow() -> NSWindow? {
        let identifier = PreferencesWindowController.windowIdentifier

        // Walk the key window up its sheet-parent chain so a Preferences sheet resolves to
        // Preferences, while a key Launcher/CmdTab panel does not.
        var candidate = NSApp.keyWindow
        while let window = candidate {
            if window.identifier == identifier {
                return window
            }
            candidate = window.sheetParent
        }

        // Activation-race fallback: keyWindow can briefly be nil before the titled Preferences
        // window settles as key, by which point mainWindow is already set. Only consulted when
        // there is no key window, so a key Launcher/CmdTab panel never reaches here.
        if NSApp.keyWindow == nil, let mainWindow = NSApp.mainWindow, mainWindow.identifier == identifier {
            return mainWindow
        }

        return nil
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
