import Foundation
import AppKit
import Carbon

/// Main controller that coordinates all components
private let hotKeySignature: OSType = 0x4C415454 // 'LATT'

private func AppControllerHotKeyHandler(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return noErr }
    let controller = Unmanaged<AppController>.fromOpaque(userData).takeUnretainedValue()
    return controller.handleHotKeyEvent(event: event)
}

/// Main controller that coordinates all components
class AppController: NSObject, WindowControllerDelegate {
    static let shared = AppController()

    private let zoneController: ZoneController
    private let windowController: WindowController
    private let configuration: Configuration
    private var eventMonitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyEventHandler: EventHandlerRef?
    private let zoneMargin: CGFloat = 5
    private var isSyncingWindows = false
    private var pendingSync = false
    private var pendingSyncExcludedZones: Set<Int> = []
    private var liveResizingZoneIndex: Int?

    private override init() {
        // Get the main screen frame
        guard let screen = NSScreen.main else {
            fatalError("No main screen found")
        }
        let screenFrame = screen.visibleFrame

        let configuration = Configuration.load()
        self.configuration = configuration
        self.zoneController = ZoneController(screenFrame: screenFrame)
        self.windowController = WindowController(ignoredBundleIdentifiers: configuration.ignoredBundleIdentifiers)

        super.init()

        self.windowController.delegate = self
        minimizeExistingApplicationWindows()
        setupKeyboardShortcuts()
        setupApplicationMonitoring()

        Logger.debug("AppController initialized")

        // Create initial placeholder for the first empty zone
        syncWindowsToZones()
    }

    deinit {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()

        if let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }
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

    func resizeZone(at index: Int, frame: CGRect) {
        guard let zone = zoneController.zone(at: index) else {
            print("Zone \(index) not found")
            return
        }

        guard zone.isEmpty else {
            print("Zone \(index) is occupied; minimize or close its window before resizing.")
            return
        }

        if zoneController.resizeZone(at: index, to: frame) {
            syncWindowsToZones()
            if let updatedZone = zoneController.zone(at: index) {
                print("Resized zone \(index) to \(updatedZone.frame)")
            } else {
                print("Zone \(index) resized")
            }
        } else {
            print("Failed to resize zone \(index)")
        }
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

    func captureFrontmostWindow() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            print("Frontmost application \(bundleId) is configured to be ignored.")
            return
        }

        guard let managed = windowController.captureFrontmostWindow() else {
            print("No frontmost window available. Make sure Accessibility permissions are granted and another app has a visible window.")
            return
        }

        if let zoneIndex = managed.zoneIndex,
           let zone = zoneController.zone(at: zoneIndex),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            print("Window \(managed.windowId) is already managed in zone \(zoneIndex)")
            return
        }

        placeNewWindow(managed)
        print("Captured window \(managed.windowId)")
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
        windowController.showWindow(managed, at: frameWithMargin(for: zone))
    }

    // MARK: - Synchronization

    /// Sync all windows to their zones, creating placeholders as needed
    private func syncWindowsToZones(excluding excludedZones: Set<Int> = []) {
        if isSyncingWindows {
            pendingSync = true
            pendingSyncExcludedZones.formUnion(excludedZones)
            return
        }
        isSyncingWindows = true
        let currentExcludedZones = excludedZones
        defer {
            isSyncingWindows = false
            if pendingSync {
                pendingSync = false
                let pendingExcluded = pendingSyncExcludedZones
                pendingSyncExcludedZones.removeAll()
                syncWindowsToZones(excluding: pendingExcluded)
            }
        }

        Logger.debug("Syncing windows to zones")

        let prunedWindowIds = windowController.pruneDestroyedExternalWindows()
        if !prunedWindowIds.isEmpty {
            for windowId in prunedWindowIds {
                zoneController.removeWindow(windowId: windowId)
            }
        }

        // Keep track of existing placeholders by zone
        var placeholdersByZone = [Int: ManagedWindow]()
        var placeholdersWithoutZone = [ManagedWindow]()
        for window in windowController.allWindows where window.isPlaceholder {
            if let zoneIndex = window.zoneIndex {
                placeholdersByZone[zoneIndex] = window
            } else {
                placeholdersWithoutZone.append(window)
            }
        }

        var placeholdersToClose = placeholdersByZone

        var assignedWindowIds = Set<Int>()

        // Then, for each zone, either show the window or create a placeholder
        for zone in zoneController.allZones {
            let displayFrame = frameWithMargin(for: zone)
            let isExcluded = currentExcludedZones.contains(zone.index)
            if let windowId = zone.windowId,
               let managed = windowController.window(withId: windowId) {
                // Move the window to match the zone frame
                windowController.moveWindow(managed, to: displayFrame)
                managed.zoneIndex = zone.index
                assignedWindowIds.insert(windowId)

                // No placeholder needed for this zone
                if let placeholder = placeholdersToClose.removeValue(forKey: zone.index) {
                    windowController.closeWindow(placeholder)
                }
            } else {
                if let existingPlaceholder = placeholdersByZone[zone.index] {
                    // Reuse existing placeholder, update its frame
                    existingPlaceholder.zoneIndex = zone.index
                    if isExcluded {
                        existingPlaceholder.appKitWindow?.orderFront(nil)
                    } else {
                        windowController.showWindow(existingPlaceholder, at: displayFrame)
                        windowController.moveWindow(existingPlaceholder, to: displayFrame)
                    }
                    placeholdersToClose.removeValue(forKey: zone.index)
                } else if let unassignedPlaceholder = placeholdersWithoutZone.popLast() {
                    unassignedPlaceholder.zoneIndex = zone.index
                    windowController.showWindow(unassignedPlaceholder, at: displayFrame)
                    windowController.moveWindow(unassignedPlaceholder, to: displayFrame)
                } else {
                    // Create a placeholder (but don't assign its ID to the zone - keep zone empty)
                    let placeholder = windowController.createPlaceholderWindow(
                        frame: displayFrame,
                        zoneIndex: zone.index
                    )
                    placeholder.zoneIndex = zone.index
                    windowController.showWindow(placeholder, at: displayFrame)
                }
            }
        }

        // Close any leftover placeholders that aren't needed
        for placeholder in placeholdersToClose.values {
            windowController.closeWindow(placeholder)
        }
        for placeholder in placeholdersWithoutZone {
            windowController.closeWindow(placeholder)
        }

        // Mark any real windows that are no longer assigned to a zone as minimized/unassigned
        for window in windowController.allWindows where !window.isPlaceholder {
            if !assignedWindowIds.contains(window.windowId) {
                window.zoneIndex = nil
            }
        }
    }

    /// Compute the frame used to render content inside a zone, honoring the spec margin
    private func frameWithMargin(for zone: Zone) -> CGRect {
        let insetX = min(zoneMargin, zone.frame.width / 2)
        let insetY = min(zoneMargin, zone.frame.height / 2)
        return zone.frame.insetBy(dx: insetX, dy: insetY)
    }

    /// Convert a content frame (placeholder or occupant window) back into the zone frame.
    private func zoneFrame(fromContentFrame frame: CGRect) -> CGRect {
        var zoneFrame = frame.insetBy(dx: -zoneMargin, dy: -zoneMargin)
        zoneFrame = clamp(frame: zoneFrame, to: zoneController.layoutBounds)
        return zoneFrame
    }

    private func applyPlaceholderResize(zoneIndex: Int, placeholderFrame: CGRect, finalize: Bool) {
        let zoneFrame = zoneFrame(fromContentFrame: placeholderFrame)
        guard zoneController.resizeZone(at: zoneIndex, to: zoneFrame) else {
            return
        }

        if finalize {
            Logger.debug("Placeholder for zone \(zoneIndex) resize finalized")
            syncWindowsToZones()
        } else {
            syncWindowsToZones(excluding: Set([zoneIndex]))
        }
    }

    private func clamp(frame: CGRect, to bounds: CGRect) -> CGRect {
        var normalized = frame.standardized

        let originX = max(bounds.minX, normalized.origin.x)
        let originY = max(bounds.minY, normalized.origin.y)
        let maxX = min(bounds.maxX, normalized.maxX)
        let maxY = min(bounds.maxY, normalized.maxY)

        normalized.origin = CGPoint(x: originX, y: originY)
        normalized.size.width = max(0, maxX - originX)
        normalized.size.height = max(0, maxY - originY)

        return normalized
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

    func placeholderLiveResizeDidBegin(zoneIndex: Int) {
        liveResizingZoneIndex = zoneIndex
    }

    func placeholderLiveResized(zoneIndex: Int, to frame: CGRect) {
        guard liveResizingZoneIndex == zoneIndex else {
            return
        }

        applyPlaceholderResize(zoneIndex: zoneIndex, placeholderFrame: frame, finalize: false)
    }

    func placeholderLiveResizeDidEnd(zoneIndex: Int, to frame: CGRect) {
        if liveResizingZoneIndex == zoneIndex {
            liveResizingZoneIndex = nil
        }

        applyPlaceholderResize(zoneIndex: zoneIndex, placeholderFrame: frame, finalize: true)
    }

    func windowManualResizeDidEnd(windowId: Int, frame: CGRect) {
        guard let managed = windowController.window(withId: windowId),
              let zoneIndex = managed.zoneIndex else {
            Logger.debug("Resize completed for window \(windowId) without a zone assignment")
            return
        }

        let zoneFrame = zoneFrame(fromContentFrame: frame)
        guard zoneController.resizeZone(at: zoneIndex, to: zoneFrame, allowOccupied: true) else {
            Logger.debug("Failed to resize zone \(zoneIndex) from window \(windowId)")
            return
        }

        Logger.debug("Applied window-driven resize for zone \(zoneIndex) from window \(windowId)")
        syncWindowsToZones()
    }

    func windowManualMoveDidEnd(windowId: Int, frame: CGRect) {
        guard let managed = windowController.window(withId: windowId),
              let zoneIndex = managed.zoneIndex,
              let zone = zoneController.zone(at: zoneIndex) else {
            Logger.debug("Move completed for window \(windowId) with no zone to snap to")
            return
        }

        let targetFrame = frameWithMargin(for: zone)
        let needsSnap = abs(targetFrame.origin.x - frame.origin.x) > 0.5 ||
            abs(targetFrame.origin.y - frame.origin.y) > 0.5 ||
            abs(targetFrame.size.width - frame.size.width) > 0.5 ||
            abs(targetFrame.size.height - frame.size.height) > 0.5

        if needsSnap {
            Logger.debug("Snapping window \(windowId) back to zone \(zoneIndex)")
            windowController.moveWindow(managed, to: targetFrame)
        }
    }

    func placeholderAllowedResizeAxes(zoneIndex: Int) -> PlaceholderResizeAxes {
        guard let zone = zoneController.zone(at: zoneIndex), zone.isEmpty else {
            return []
        }

        let zoneCount = zoneController.allZones.count
        switch zoneCount {
        case 0, 1:
            return []
        case 2:
            return [.horizontal]
        case 3:
            if zoneIndex == 1 {
                return [.horizontal]
            } else {
                return [.horizontal, .vertical]
            }
        default:
            return []
        }
    }

    func windowController(_ controller: WindowController, didCaptureExternalWindow window: ManagedWindow) {
        placeNewWindow(window)
    }

    // MARK: - Startup helpers

    private func minimizeExistingApplicationWindows() {
        // No-op: leave existing application windows untouched for faster startup.
    }

    private enum HotKeyID: UInt32 {
        case addZone = 1
        case removeZone = 2
    }

    private func setupKeyboardShortcuts() {
        registerGlobalHotKeys()

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self = self else { return event }
            if self.handleLocalShortcut(event: event) {
                return nil
            }
            return event
        }) {
            eventMonitors.append(localMonitor)
        }
    }

    private func setupApplicationMonitoring() {
        let center = NSWorkspace.shared.notificationCenter

        let activationObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationEvent(application)
        }
        workspaceObservers.append(activationObserver)

        let launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationEvent(application)
        }
        workspaceObservers.append(launchObserver)

        let unhideObserver = center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationEvent(application)
        }
        workspaceObservers.append(unhideObserver)

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            handleApplicationEvent(frontmost)
        }
    }

    private func handleApplicationEvent(_ application: NSRunningApplication?) {
        guard let application else {
            return
        }

        guard shouldManage(application: application) else {
            return
        }

        scheduleCapture(for: application, delay: 0.0)
        scheduleCapture(for: application, delay: 0.4)
    }

    private func scheduleCapture(for application: NSRunningApplication, delay: TimeInterval) {
        let pid = application.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard let refreshedApplication = NSRunningApplication(processIdentifier: pid) else { return }
            guard self.shouldManage(application: refreshedApplication) else { return }

            let newWindows = self.windowController.captureWindows(for: refreshedApplication, notifyDelegate: false, allowExisting: false)
            for window in newWindows {
                self.placeNewWindow(window)
            }
        }
    }

    private func shouldManage(application: NSRunningApplication) -> Bool {
        guard !application.isTerminated else {
            return false
        }
        if application.processIdentifier == getpid() {
            return false
        }
        if let bundleId = application.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            return false
        }
        return true
    }

    @discardableResult
    private func handleLocalShortcut(event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.modifierFlags.contains(.control) else {
            return false
        }

        switch Int(event.keyCode) {
        case kVK_ANSI_Equal:
            Logger.debug("Local shortcut add zone triggered")
            triggerShortcut(.addZone)
            return true
        case kVK_ANSI_Minus:
            Logger.debug("Local shortcut remove zone triggered")
            triggerShortcut(.removeZone)
            return true
        default:
            return false
        }
    }

    fileprivate func handleHotKeyEvent(event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.signature == hotKeySignature else {
            return status
        }

        switch HotKeyID(rawValue: hotKeyID.id) {
        case .addZone:
            Logger.debug("Hotkey add zone triggered")
            triggerShortcut(.addZone)
        case .removeZone:
            Logger.debug("Hotkey remove zone triggered")
            triggerShortcut(.removeZone)
        case .none:
            break
        }

        return noErr
    }

    private func registerGlobalHotKeys() {
        installHotKeyEventHandler()
        registerHotKey(keyCode: UInt32(kVK_ANSI_Equal), id: HotKeyID.addZone.rawValue)
        registerHotKey(keyCode: UInt32(kVK_ANSI_Minus), id: HotKeyID.removeZone.rawValue)
    }

    private func installHotKeyEventHandler() {
        guard hotKeyEventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            AppControllerHotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyEventHandler
        )

        if status != noErr {
            Logger.debug("Failed to install hotkey handler with status \(status)")
        }
    }

    private func registerHotKey(keyCode: UInt32, id: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
        let modifierFlags = UInt32(cmdKey | controlKey)
        let status = RegisterEventHotKey(
            keyCode,
            modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let hotKeyRef {
            hotKeyRefs.append(hotKeyRef)
            Logger.debug("Registered hotkey id \(id) keyCode \(keyCode)")
        } else if status != noErr {
            Logger.debug("Failed to register hotkey \(id) with status \(status)")
        }
    }

    private func triggerShortcut(_ action: HotKeyID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch action {
            case .addZone:
                self.addZone()
            case .removeZone:
                guard let highestIndex = self.zoneController.highestIndexZone()?.index else { return }
                self.removeZone(at: highestIndex)
            }
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

    func resizeZoneJSON(at index: Int, frame: CGRect) -> [String: Any] {
        guard let zone = zoneController.zone(at: index) else {
            return ["error": "Zone \(index) not found"]
        }

        guard zone.isEmpty else {
            return ["error": "Zone \(index) is occupied; minimize or close its window before resizing."]
        }

        guard zoneController.resizeZone(at: index, to: frame) else {
            return ["error": "Failed to resize zone \(index)"]
        }

        syncWindowsToZones()

        guard let updatedZone = zoneController.zone(at: index) else {
            return ["error": "Zone \(index) unavailable after resize"]
        }

        return [
            "zone_index": updatedZone.index,
            "frame": [
                "x": updatedZone.frame.origin.x,
                "y": updatedZone.frame.origin.y,
                "width": updatedZone.frame.width,
                "height": updatedZone.frame.height
            ],
            "zone_count": zoneController.allZones.count
        ]
    }

    func createWindowJSON() -> [String: Any] {
        let managed = windowController.createTestWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        placeNewWindow(managed)
        return [
            "window_id": managed.windowId,
            "zone_index": managed.zoneIndex as Any
        ]
    }

    func captureFrontmostWindowJSON() -> [String: Any] {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            return ["error": "Frontmost application \(bundleId) is configured to be ignored"]
        }

        guard let managed = windowController.captureFrontmostWindow() else {
            return ["error": "No frontmost window available or Accessibility permissions missing"]
        }

        if let zoneIndex = managed.zoneIndex,
           let zone = zoneController.zone(at: zoneIndex),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            return [
                "window_id": managed.windowId,
                "zone_index": zoneIndex,
                "message": "Already managed"
            ]
        }

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
