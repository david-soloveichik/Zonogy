import Foundation
import AppKit

/// Main controller that coordinates all components
class AppController: NSObject, WindowControllerDelegate {
    static let shared = AppController()

    private let zoneController: ZoneController
    private let windowController: WindowController
    private var eventMonitors: [Any] = []

    private override init() {
        // Get the main screen frame
        guard let screen = NSScreen.main else {
            fatalError("No main screen found")
        }
        let screenFrame = screen.visibleFrame

        self.zoneController = ZoneController(screenFrame: screenFrame)
        self.windowController = WindowController()

        super.init()

        self.windowController.delegate = self
        minimizeExistingApplicationWindows()
        setupKeyboardShortcuts()

        Logger.debug("AppController initialized")

        // Create initial placeholder for the first empty zone
        syncWindowsToZones()
    }

    // MARK: - Zone Management

    func addZone() {
        guard let newZone = zoneController.addZone() else {
            print("Failed to add zone (max 3 zones)")
            return
        }
        syncWindowsToZones()
        print("Added zone \(newZone.index)")
    }

    func removeZone(at index: Int) {
        guard let removalResult = zoneController.removeZone(at: index) else {
            print("Failed to remove zone \(index)")
            return
        }

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            placeNewWindow(managed)
        }

        syncWindowsToZones()
        print("Removed zone \(index)")
    }

    // MARK: - Window Management

    func createWindow() {
        let managed = windowController.createTestWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        placeNewWindow(managed)
        print("Created window \(managed.windowId)")
    }

    func closeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        // Remove from zone
        zoneController.removeWindow(windowId: windowId)

        // Close the window
        windowController.closeWindow(managed)

        // Sync to create placeholder if needed
        syncWindowsToZones()

        print("Closed window \(windowId)")
    }

    func minimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        windowController.minimizeWindow(managed)

        // Remove from zone and sync (delegate may not fire in CLI environment)
        zoneController.removeWindow(windowId: windowId)
        syncWindowsToZones()

        print("Minimized window \(windowId)")
    }

    func unminimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        windowController.unminimizeWindow(managed)

        // Place the window using normal placement logic
        placeNewWindow(managed)

        print("Unminimized window \(windowId)")
    }

    // MARK: - Window Placement Logic

    private func placeNewWindow(_ managed: ManagedWindow) {
        // Clear any previous zone assignment for this window.
        zoneController.removeWindow(windowId: managed.windowId)
        managed.zoneIndex = nil

        if let emptyZone = zoneController.findEmptyZone() {
            // Place in the empty zone with lowest index
            assignWindowToZone(managed, zone: emptyZone)
        } else {
            // Replace the window in the highest index zone
            if let highestZone = zoneController.highestIndexZone() {
                // First, get the old window if there is one
                if let oldWindowId = highestZone.windowId,
                   let oldWindow = windowController.window(withId: oldWindowId) {
                    // Move new window to position first (for smooth UI)
                    assignWindowToZone(managed, zone: highestZone)
                    // Clear the old window's assignment before minimizing it
                    oldWindow.zoneIndex = nil
                    // Then minimize the old window
                    windowController.minimizeWindow(oldWindow)
                } else {
                    assignWindowToZone(managed, zone: highestZone)
                }
            }
        }
    }

    private func assignWindowToZone(_ managed: ManagedWindow, zone: Zone) {
        // Find and close any placeholder window in this zone
        for window in windowController.allWindows {
            if window.isPlaceholder && window.zoneIndex == zone.index {
                windowController.closeWindow(window)
            }
        }

        // Assign to zone
        zoneController.assignWindow(windowId: managed.windowId, toZoneIndex: zone.index)
        managed.zoneIndex = zone.index

        // Position the window
        windowController.showWindow(managed, at: zone.frame)
    }

    // MARK: - Synchronization

    /// Sync all windows to their zones, creating placeholders as needed
    private func syncWindowsToZones() {
        Logger.debug("Syncing windows to zones")

        // First, close all placeholder windows
        for window in windowController.allWindows where window.isPlaceholder {
            windowController.closeWindow(window)
        }

        var assignedWindowIds = Set<Int>()

        // Then, for each zone, either show the window or create a placeholder
        for zone in zoneController.allZones {
            if let windowId = zone.windowId,
               let managed = windowController.window(withId: windowId) {
                // Move the window to match the zone frame
                windowController.moveWindow(managed, to: zone.frame)
                managed.zoneIndex = zone.index
                assignedWindowIds.insert(windowId)
            } else {
                // Create a placeholder (but don't assign its ID to the zone - keep zone empty)
                let placeholder = windowController.createPlaceholderWindow(
                    frame: zone.frame,
                    zoneIndex: zone.index
                )
                placeholder.zoneIndex = zone.index
                windowController.showWindow(placeholder, at: zone.frame)
            }
        }

        // Mark any real windows that are no longer assigned to a zone as minimized/unassigned
        for window in windowController.allWindows where !window.isPlaceholder {
            if !assignedWindowIds.contains(window.windowId) {
                window.zoneIndex = nil
            }
        }
    }

    // MARK: - WindowControllerDelegate

    func placeholderCloseRequested(zoneIndex: Int) {
        Logger.debug("Placeholder close requested for zone \(zoneIndex)")
        removeZone(at: zoneIndex)
    }

    func windowWillClose(windowId: Int) {
        Logger.debug("Window \(windowId) will close")
        zoneController.removeWindow(windowId: windowId)
        syncWindowsToZones()
    }

    func windowDidMiniaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did miniaturize")
        zoneController.removeWindow(windowId: windowId)
        syncWindowsToZones()
    }

    func windowDidDeminiaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did deminiaturize")
        guard let managed = windowController.window(withId: windowId) else { return }
        placeNewWindow(managed)
    }

    // MARK: - Startup helpers

    private func minimizeExistingApplicationWindows() {
        for window in NSApplication.shared.windows where !window.isMiniaturized {
            window.miniaturize(nil)
        }
    }

    private enum ShortcutSource {
        case global
        case local
    }

    private func setupKeyboardShortcuts() {
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleShortcut(event: event, source: .global)
        }) {
            eventMonitors.append(globalMonitor)
        }

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self = self else { return event }
            if self.handleShortcut(event: event, source: .local) {
                return nil
            }
            return event
        }) {
            eventMonitors.append(localMonitor)
        }
    }

    @discardableResult
    private func handleShortcut(event: NSEvent, source: ShortcutSource) -> Bool {
        if source == .global && NSApp.isActive {
            return false
        }

        guard event.modifierFlags.contains(.command),
              event.modifierFlags.contains(.control),
              let characters = event.charactersIgnoringModifiers else {
            return false
        }

        switch characters {
        case "=":
            DispatchQueue.main.async { [weak self] in
                self?.addZone()
            }
            return true
        case "-":
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let highestIndex = self.zoneController.highestIndexZone()?.index else { return }
                self.removeZone(at: highestIndex)
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Inspection

    func listZones() {
        print("\nCurrent zones:")
        for zone in zoneController.allZones {
            let windowInfo = zone.windowId.map { "window \($0)" } ?? "empty"
            print("  Zone \(zone.index): \(windowInfo), frame: \(zone.frame)")
        }
        print("")
    }

    func relayout() {
        zoneController.relayout()
        syncWindowsToZones()
        print("Layout recalculated")
    }

    func windowInfo(windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        print("\nWindow \(windowId):")
        print("  Type: \(managed.isPlaceholder ? "placeholder" : "test")")
        print("  Zone: \(managed.zoneIndex?.description ?? "none (minimized)")")
        print("  Actual frame: \(managed.actualFrame)")

        if let zoneIndex = managed.zoneIndex,
           let zone = zoneController.zone(at: zoneIndex) {
            print("  Zone frame: \(zone.frame)")
        }
        print("")
    }

    func printFrames() {
        print("\nAll window frames:")
        for window in windowController.allWindows {
            let type = window.isPlaceholder ? "placeholder" : "test"
            print("  Window \(window.windowId) (\(type)): \(window.actualFrame)")
        }
        print("")
    }

    // MARK: - JSON API for Socket Server

    func addZoneJSON() -> [String: Any] {
        guard let newZone = zoneController.addZone() else {
            return ["error": "Failed to add zone (max 3 zones)"]
        }
        syncWindowsToZones()
        return [
            "zone_index": newZone.index,
            "zone_count": zoneController.allZones.count
        ]
    }

    func removeZoneJSON(at index: Int) -> [String: Any] {
        guard let removalResult = zoneController.removeZone(at: index) else {
            return ["error": "Failed to remove zone \(index)"]
        }

        var response: [String: Any] = [
            "removed_index": index,
            "zone_count": zoneController.allZones.count,
            "removed_window_id": removalResult.removedWindowId as Any
        ]

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            placeNewWindow(managed)
            response["reassigned_window_id"] = managed.windowId
            response["reassigned_zone_index"] = managed.zoneIndex as Any
        }

        syncWindowsToZones()
        return response
    }

    func createWindowJSON() -> [String: Any] {
        let managed = windowController.createTestWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        placeNewWindow(managed)
        return [
            "window_id": managed.windowId,
            "zone_index": managed.zoneIndex as Any
        ]
    }

    func closeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        zoneController.removeWindow(windowId: windowId)
        windowController.closeWindow(managed)
        syncWindowsToZones()

        return ["window_id": windowId]
    }

    func minimizeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        windowController.minimizeWindow(managed)
        zoneController.removeWindow(windowId: windowId)
        syncWindowsToZones()

        return ["window_id": windowId]
    }

    func unminimizeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        windowController.unminimizeWindow(managed)
        placeNewWindow(managed)

        return [
            "window_id": windowId,
            "zone_index": managed.zoneIndex as Any
        ]
    }

    func listZonesJSON() -> [String: Any] {
        let zones = zoneController.allZones.map { zone -> [String: Any] in
            [
                "index": zone.index,
                "window_id": zone.windowId as Any,
                "frame": [
                    "x": zone.frame.origin.x,
                    "y": zone.frame.origin.y,
                    "width": zone.frame.width,
                    "height": zone.frame.height
                ]
            ]
        }
        return ["zones": zones]
    }

    func relayoutJSON() -> [String: Any] {
        zoneController.relayout()
        syncWindowsToZones()
        return ["zone_count": zoneController.allZones.count]
    }

    func windowInfoJSON(windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        var result: [String: Any] = [
            "window_id": windowId,
            "is_placeholder": managed.isPlaceholder,
            "zone_index": managed.zoneIndex as Any,
            "actual_frame": [
                "x": managed.actualFrame.origin.x,
                "y": managed.actualFrame.origin.y,
                "width": managed.actualFrame.width,
                "height": managed.actualFrame.height
            ]
        ]

        if let zoneIndex = managed.zoneIndex,
           let zone = zoneController.zone(at: zoneIndex) {
            result["zone_frame"] = [
                "x": zone.frame.origin.x,
                "y": zone.frame.origin.y,
                "width": zone.frame.width,
                "height": zone.frame.height
            ]
        }

        return result
    }

    func printFramesJSON() -> [String: Any] {
        let frames = windowController.allWindows.map { window -> [String: Any] in
            [
                "window_id": window.windowId,
                "is_placeholder": window.isPlaceholder,
                "frame": [
                    "x": window.actualFrame.origin.x,
                    "y": window.actualFrame.origin.y,
                    "width": window.actualFrame.width,
                    "height": window.actualFrame.height
                ]
            ]
        }
        return ["windows": frames]
    }
}
