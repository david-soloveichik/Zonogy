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
}
