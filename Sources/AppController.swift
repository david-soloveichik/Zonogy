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
    private struct ScreenContext {
        var descriptor: ScreenDescriptor
        let zoneController: ZoneController
    }

    private struct ZoneKey: Hashable {
        let screenId: CGDirectDisplayID
        let index: Int
    }

    static let shared = AppController()

    private let windowController: WindowController
    private let configuration: Configuration
    private var screenContexts: [CGDirectDisplayID: ScreenContext] = [:]
    private var screenOrder: [CGDirectDisplayID] = []
    private let primaryScreenId: CGDirectDisplayID
    private let primaryScreenBounds: CGRect
    private var eventMonitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyEventHandler: EventHandlerRef?
    private let zoneMargin: CGFloat = 5
    private var isSyncingWindows = false
    private var pendingSync = false
    private var pendingSyncExcludedZones: Set<ZoneKey> = []
    private var liveResizingZoneKey: ZoneKey?
    private var lastActiveApplicationPid: pid_t?
    private var placeholderIdToZoneKey: [Int: ZoneKey] = [:]

    private override init() {
        let configuration = Configuration.load()
        self.configuration = configuration

        let screens = NSScreen.screens
        guard let primaryScreen = screens.first,
              let primaryId = AppController.displayId(for: primaryScreen) else {
            fatalError("No primary screen found")
        }

        self.primaryScreenId = primaryId
        self.primaryScreenBounds = primaryScreen.frame

        self.windowController = WindowController(
            ignoredBundleIdentifiers: configuration.ignoredBundleIdentifiers,
            primaryScreenBounds: primaryScreen.frame
        )

        var initialContexts: [CGDirectDisplayID: ScreenContext] = [:]
        var order: [CGDirectDisplayID] = []

        for screen in screens {
            guard let displayId = AppController.displayId(for: screen) else {
                continue
            }

            let descriptor = ScreenDescriptor(
                displayId: displayId,
                localizedName: screen.localizedName,
                cocoaBounds: screen.frame,
                visibleCocoaBounds: screen.visibleFrame,
                primaryBounds: primaryScreen.frame
            )
            let zoneController = ZoneController(screenFrame: descriptor.visibleScreenBounds)
            initialContexts[displayId] = ScreenContext(descriptor: descriptor, zoneController: zoneController)
            order.append(displayId)
        }

        super.init()

        self.screenContexts = initialContexts
        self.screenOrder = order
        self.windowController.delegate = self
        minimizeExistingApplicationWindows()
        setupKeyboardShortcuts()
        setupApplicationMonitoring()

        Logger.debug("AppController initialized with multi-screen support across \(screenContexts.count) display(s)")

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
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            print("Failed to add zone (max 3 zones)")
            return
        }
        syncWindowsToZones()
        print("Added zone \(newZone.index) on \(context.descriptor.localizedName)")
    }

    func removeZone(at index: Int) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard performRemoveZone(at: index, on: screenId, announce: true, context: context) != nil else {
            print("Failed to remove zone \(index)")
            return
        }
    }

    private func performRemoveZone(
        at index: Int,
        on screenId: CGDirectDisplayID,
        announce: Bool,
        context: ScreenContext? = nil
    ) -> ZoneController.RemovalResult? {
        let context = context ?? screenContexts[screenId]
        guard let context else {
            return nil
        }

        guard let removalResult = context.zoneController.removeZone(at: index) else {
            return nil
        }

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            placeNewWindow(managed, preferredScreenId: screenId)
        }

        syncWindowsToZones()

        if announce {
            print("Removed zone \(index) on \(context.descriptor.localizedName)")
        }
        return removalResult
    }

    func resizeZone(at index: Int, frame: CGRect) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard let zone = context.zoneController.zone(at: index) else {
            print("Zone \(index) not found on \(context.descriptor.localizedName)")
            return
        }

        guard zone.isEmpty else {
            print("Zone \(index) is occupied; minimize or close its window before resizing.")
            return
        }

        if context.zoneController.resizeZone(at: index, to: frame) {
            syncWindowsToZones()
            if let updatedZone = context.zoneController.zone(at: index) {
                print("Resized zone \(index) on \(context.descriptor.localizedName) to \(updatedZone.frame)")
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
        removeWindowFromAllZones(windowId: windowId)

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
        removeWindowFromAllZones(windowId: windowId)
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
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            print("Window \(managed.windowId) is already managed in zone \(zoneIndex)")
            return
        }

        placeNewWindow(managed)
        print("Captured window \(managed.windowId)")
    }

    // MARK: - Window Placement Logic

    private func placeNewWindow(_ managed: ManagedWindow, preferredScreenId: CGDirectDisplayID? = nil) {
        removeWindowFromAllZones(windowId: managed.windowId)
        managed.zoneIndex = nil

        let targetScreenId = preferredScreenId ?? detectScreenId(for: managed) ?? activeScreenId()
        guard let controller = zoneController(for: targetScreenId),
              let descriptor = descriptor(for: targetScreenId) else {
            return
        }

        if let emptyZone = controller.findEmptyZone() {
            assignWindowToZone(managed, zone: emptyZone, screenId: targetScreenId, descriptor: descriptor)
        } else if let highestZone = controller.highestIndexZone() {
            if let oldWindowId = highestZone.windowId,
               let oldWindow = windowController.window(withId: oldWindowId) {
                assignWindowToZone(managed, zone: highestZone, screenId: targetScreenId, descriptor: descriptor)
                clearManagedWindowZone(oldWindow)
                windowController.minimizeWindow(oldWindow)
            } else {
                assignWindowToZone(managed, zone: highestZone, screenId: targetScreenId, descriptor: descriptor)
            }
        }
    }

    private func assignWindowToZone(
        _ managed: ManagedWindow,
        zone: Zone,
        screenId: CGDirectDisplayID,
        descriptor: ScreenDescriptor
    ) {
        for window in windowController.allWindows where window.isPlaceholder {
            if window.zoneIndex == zone.index && window.screenDisplayId == screenId {
                windowController.closeWindow(window)
                forgetPlaceholder(windowId: window.windowId)
            }
        }

        zoneController(for: screenId)?.assignWindow(windowId: managed.windowId, toZoneIndex: zone.index)
        setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)

        let displayFrame = frameWithMargin(for: zone)
        windowController.showWindow(managed, at: displayFrame, on: descriptor)
    }

    // MARK: - Synchronization

    /// Sync all windows to their zones, creating placeholders as needed
    private func syncWindowsToZones(excluding excludedZones: Set<ZoneKey> = []) {
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
                removeWindowFromAllZones(windowId: windowId)
            }
        }

        var placeholdersByKey: [ZoneKey: ManagedWindow] = [:]
        var placeholdersWithoutKey: [ManagedWindow] = []
        for window in windowController.allWindows where window.isPlaceholder {
            if let key = placeholderIdToZoneKey[window.windowId] {
                placeholdersByKey[key] = window
            } else if let screenId = window.screenDisplayId,
                      let zoneIndex = window.zoneIndex {
                let key = ZoneKey(screenId: screenId, index: zoneIndex)
                recordPlaceholder(window, key: key)
                placeholdersByKey[key] = window
            } else {
                placeholdersWithoutKey.append(window)
            }
        }

        var placeholdersToClose = placeholdersByKey
        var assignedWindowIds = Set<Int>()

        for screenId in screenOrder {
            guard let context = screenContexts[screenId],
                  let descriptor = descriptor(for: screenId) else {
                continue
            }
            let controller = context.zoneController

            for zone in controller.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                let isExcluded = currentExcludedZones.contains(key)
                let displayFrame = frameWithMargin(for: zone)

                if let windowId = zone.windowId,
                   let managed = windowController.window(withId: windowId) {
                    windowController.moveWindow(managed, to: displayFrame, on: descriptor)
                    setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
                    assignedWindowIds.insert(windowId)

                    if let placeholder = placeholdersToClose.removeValue(forKey: key) {
                        windowController.closeWindow(placeholder)
                        forgetPlaceholder(windowId: placeholder.windowId)
                    }
                } else {
                    if let placeholder = placeholdersByKey[key] {
                        recordPlaceholder(placeholder, key: key)
                        if isExcluded {
                            placeholder.appKitWindow?.orderFront(nil)
                        } else {
                            windowController.showWindow(placeholder, at: displayFrame, on: descriptor)
                            windowController.moveWindow(placeholder, to: displayFrame, on: descriptor)
                        }
                        placeholdersToClose.removeValue(forKey: key)
                    } else if let unassigned = placeholdersWithoutKey.popLast() {
                        recordPlaceholder(unassigned, key: key)
                        windowController.showWindow(unassigned, at: displayFrame, on: descriptor)
                        windowController.moveWindow(unassigned, to: displayFrame, on: descriptor)
                    } else {
                        let placeholder = windowController.createPlaceholderWindow(
                            frame: displayFrame,
                            zoneIndex: zone.index,
                            on: descriptor
                        )
                        recordPlaceholder(placeholder, key: key)
                        windowController.showWindow(placeholder, at: displayFrame, on: descriptor)
                    }
                }
            }
        }

        for placeholder in placeholdersToClose.values {
            windowController.closeWindow(placeholder)
            forgetPlaceholder(windowId: placeholder.windowId)
        }
        for placeholder in placeholdersWithoutKey {
            windowController.closeWindow(placeholder)
            forgetPlaceholder(windowId: placeholder.windowId)
        }

        for window in windowController.allWindows where !window.isPlaceholder {
            if !assignedWindowIds.contains(window.windowId) {
                clearManagedWindowZone(window)
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
    private func zoneFrame(fromContentFrame frame: CGRect, in context: ScreenContext) -> CGRect {
        var zoneFrame = frame.insetBy(dx: -zoneMargin, dy: -zoneMargin)
        zoneFrame = clamp(frame: zoneFrame, to: context.zoneController.layoutBounds)
        return zoneFrame
    }

    private func applyPlaceholderResize(zoneKey: ZoneKey, placeholderFrame: CGRect, finalize: Bool) {
        guard let context = screenContexts[zoneKey.screenId] else {
            return
        }

        let zoneFrame = zoneFrame(fromContentFrame: placeholderFrame, in: context)
        guard context.zoneController.resizeZone(at: zoneKey.index, to: zoneFrame) else {
            return
        }

        if finalize {
            Logger.debug("Placeholder for zone \(zoneKey.index) on display \(zoneKey.screenId) resize finalized")
            syncWindowsToZones()
        } else {
            syncWindowsToZones(excluding: Set([zoneKey]))
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

    private static func displayId(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private func activeScreenId() -> CGDirectDisplayID {
        if let main = NSScreen.main,
           let id = AppController.displayId(for: main),
           screenContexts[id] != nil {
            return id
        }
        return primaryScreenId
    }

    private func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor? {
        screenContexts[screenId]?.descriptor
    }

    private func zoneController(for screenId: CGDirectDisplayID) -> ZoneController? {
        screenContexts[screenId]?.zoneController
    }

    private func removeWindowFromAllZones(windowId: Int) {
        for context in screenContexts.values {
            context.zoneController.removeWindow(windowId: windowId)
        }
    }

    private func zoneKey(for screenId: CGDirectDisplayID, index: Int) -> ZoneKey {
        ZoneKey(screenId: screenId, index: index)
    }

    private func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?) {
        managed.screenDisplayId = screenId
        managed.zoneIndex = zoneIndex
    }

    private func clearManagedWindowZone(_ managed: ManagedWindow) {
        managed.zoneIndex = nil
        managed.screenDisplayId = nil
    }

    private func recordPlaceholder(_ placeholder: ManagedWindow, key: ZoneKey) {
        placeholderIdToZoneKey[placeholder.windowId] = key
        windowController.refreshPlaceholderMetadata(placeholder, screenId: key.screenId, zoneIndex: key.index)
    }

    private func forgetPlaceholder(windowId: Int) {
        placeholderIdToZoneKey.removeValue(forKey: windowId)
    }

    private func detectScreenId(for managed: ManagedWindow) -> CGDirectDisplayID? {
        if let existing = managed.screenDisplayId, screenContexts[existing] != nil {
            return existing
        }

        guard let cocoaFrame = cocoaFrame(for: managed) else {
            return nil
        }

        var bestId: CGDirectDisplayID?
        var largestArea: CGFloat = 0

        for (screenId, context) in screenContexts {
            let intersection = cocoaFrame.intersection(context.descriptor.cocoaBounds)
            if intersection.isNull {
                continue
            }
            let area = intersection.width * intersection.height
            if area > largestArea {
                largestArea = area
                bestId = screenId
            }
        }

        if let bestId, largestArea > 0 {
            return bestId
        }

        for (screenId, context) in screenContexts {
            if context.descriptor.cocoaBounds.contains(cocoaFrame.origin) {
                return screenId
            }
        }

        return nil
    }

    private func cocoaFrame(for managed: ManagedWindow) -> CGRect? {
        switch managed.backing {
        case .appKit(let window):
            return window.frame
        case .accessibility(let element, _, _):
            guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
                  let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
                return nil
            }
            let accessibilityFrame = CGRect(origin: position, size: size)
            return CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: accessibilityFrame,
                primaryScreenBounds: primaryScreenBounds
            )
        }
    }

    // MARK: - WindowControllerDelegate

    func windowFocusChanged(pid: pid_t) {
        // When focus changes in an application, validate its windows
        // This catches window closures that didn't fire destroy notifications
        validateWindowsForApplication(pid: pid)
    }

    func placeholderCloseRequested(screenId: CGDirectDisplayID, zoneIndex: Int) {
        Logger.debug("Placeholder close requested for zone \(zoneIndex) on display \(screenId)")
        _ = performRemoveZone(at: zoneIndex, on: screenId, announce: false)
    }

    func windowWillClose(windowId: Int) {
        Logger.debug("Window \(windowId) will close")
        if let managed = windowController.window(withId: windowId), managed.isPlaceholder {
            forgetPlaceholder(windowId: windowId)
        }
        removeWindowFromAllZones(windowId: windowId)
        syncWindowsToZones()
    }

    func windowDidMiniaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did miniaturize")
        removeWindowFromAllZones(windowId: windowId)
        syncWindowsToZones()
    }

    func windowDidDeminiaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did deminiaturize")
        guard let managed = windowController.window(withId: windowId) else { return }
        placeNewWindow(managed)
    }

    func placeholderLiveResizeDidBegin(screenId: CGDirectDisplayID, zoneIndex: Int) {
        liveResizingZoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
    }

    func placeholderLiveResized(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect) {
        let key = ZoneKey(screenId: screenId, index: zoneIndex)
        guard liveResizingZoneKey == key else {
            return
        }

        applyPlaceholderResize(zoneKey: key, placeholderFrame: frame, finalize: false)
    }

    func placeholderLiveResizeDidEnd(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect) {
        let key = ZoneKey(screenId: screenId, index: zoneIndex)
        if liveResizingZoneKey == key {
            liveResizingZoneKey = nil
        }

        applyPlaceholderResize(zoneKey: key, placeholderFrame: frame, finalize: true)
    }

    func windowManualResizeDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect) {
        guard let screenId,
              let context = screenContexts[screenId],
              let managed = windowController.window(withId: windowId),
              let zoneIndex = managed.zoneIndex else {
            Logger.debug("Resize completed for window \(windowId) without a zone assignment")
            return
        }

        let zoneFrame = zoneFrame(fromContentFrame: frame, in: context)
        guard context.zoneController.resizeZone(at: zoneIndex, to: zoneFrame, allowOccupied: true) else {
            Logger.debug("Failed to resize zone \(zoneIndex) from window \(windowId)")
            return
        }

        Logger.debug("Applied window-driven resize for zone \(zoneIndex) from window \(windowId)")
        syncWindowsToZones()
    }

    func windowManualMoveDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect) {
        guard let screenId,
              let context = screenContexts[screenId],
              let managed = windowController.window(withId: windowId),
              let zoneIndex = managed.zoneIndex,
              let zone = context.zoneController.zone(at: zoneIndex),
              let descriptor = descriptor(for: screenId) else {
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
            windowController.moveWindow(managed, to: targetFrame, on: descriptor)
        }
    }

    func placeholderAllowedResizeAxes(screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderResizeAxes {
        guard let context = screenContexts[screenId],
              let zone = context.zoneController.zone(at: zoneIndex), zone.isEmpty else {
            return []
        }

        let zoneCount = context.zoneController.allZones.count
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

    func screenDescriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor? {
        descriptor(for: screenId)
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

            // When switching applications, validate windows for the previously active app
            // This catches window closures that happened while the app was active
            if let previousPid = self.lastActiveApplicationPid {
                self.validateWindowsForApplication(pid: previousPid)
            }

            if let application = application {
                self.lastActiveApplicationPid = application.processIdentifier
            }

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

        // Listen to deactivation and hide events to detect window changes
        let deactivationObserver = center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationStateChange(application)
        }
        workspaceObservers.append(deactivationObserver)

        let hideObserver = center.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationStateChange(application)
        }
        workspaceObservers.append(hideObserver)

        let terminateObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationTermination(application)
        }
        workspaceObservers.append(terminateObserver)

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            lastActiveApplicationPid = frontmost.processIdentifier
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

    private func handleApplicationStateChange(_ application: NSRunningApplication?) {
        guard let application else {
            return
        }

        guard shouldManage(application: application) else {
            return
        }

        // When an application changes state (deactivate/hide), validate all its windows
        // This catches window closures that didn't fire destroy notifications
        validateWindowsForApplication(pid: application.processIdentifier)
    }

    private func handleApplicationTermination(_ application: NSRunningApplication?) {
        guard let application else {
            return
        }

        // When an application terminates, prune all its windows immediately
        let prunedWindowIds = windowController.pruneDestroyedWindowsForPid(application.processIdentifier)
        if !prunedWindowIds.isEmpty {
            Logger.debug("Application terminated, pruned \(prunedWindowIds.count) windows")
            for windowId in prunedWindowIds {
                removeWindowFromAllZones(windowId: windowId)
            }
            syncWindowsToZones()
        }
    }

    private func validateWindowsForApplication(pid: pid_t) {
        // Check if any managed windows from this application have been destroyed
        let prunedWindowIds = windowController.pruneDestroyedWindowsForPid(pid)
        if !prunedWindowIds.isEmpty {
            Logger.debug("Validated windows for pid \(pid), pruned \(prunedWindowIds.count) destroyed windows")
            for windowId in prunedWindowIds {
                    removeWindowFromAllZones(windowId: windowId)
            }
            syncWindowsToZones()
        }
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
                let screenId = self.activeScreenId()
                guard let highestIndex = self.zoneController(for: screenId)?.highestIndexZone()?.index else { return }
                _ = self.performRemoveZone(at: highestIndex, on: screenId, announce: true)
            }
        }
    }

    // MARK: - Inspection

    func listZones() {
        print("\nCurrent zones:")
        for screenId in screenOrder {
            guard let context = screenContexts[screenId] else { continue }
            print("  Screen \(context.descriptor.localizedName) [\(screenId)]:")
            for zone in context.zoneController.allZones {
                let windowInfo = zone.windowId.map { "window \($0)" } ?? "empty"
                print("    Zone \(zone.index): \(windowInfo), frame: \(zone.frame)")
            }
        }
        print("")
    }

    func relayout() {
        for context in screenContexts.values {
            context.zoneController.relayout()
        }
        syncWindowsToZones()
        print("Layouts recalculated")
    }

    func windowInfo(windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        let type: String
        if managed.isPlaceholder {
            type = "placeholder"
        } else {
            switch managed.backing {
            case .appKit:
                type = "test"
            case .accessibility:
                type = "external"
            }
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
            descriptor(for: id)
        }
        let actualFrame: CGRect
        if let screenDescriptor {
            actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: screenDescriptor)
        } else if let fallback = windowController.actualFrameInScreenCoordinates(for: managed) {
            actualFrame = fallback
        } else {
            actualFrame = .zero
        }

        print("\nWindow \(windowId):")
        print("  Type: \(type)")
        if let screenId, let screenDescriptor {
            print("  Screen: \(screenDescriptor.localizedName) [\(screenId)]")
        } else {
            print("  Screen: unknown")
        }
        print("  Zone: \(managed.zoneIndex?.description ?? "none (minimized)")")
        print("  Actual frame: \(actualFrame)")

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex) {
            print("  Zone frame: \(zone.frame)")
        }
        print("")
    }

    func printFrames() {
        print("\nAll window frames:")
        for window in windowController.allWindows {
            let type: String
            if window.isPlaceholder {
                type = "placeholder"
            } else {
                switch window.backing {
                case .appKit:
                    type = "test"
                case .accessibility:
                    type = "external"
                }
            }
            let screenId = window.screenDisplayId ?? detectScreenId(for: window)
            let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
                descriptor(for: id)
            }
            let actualFrame: CGRect
            if let screenDescriptor {
                actualFrame = windowController.actualFrameInScreenCoordinates(for: window, on: screenDescriptor)
            } else if let fallback = windowController.actualFrameInScreenCoordinates(for: window) {
                actualFrame = fallback
            } else {
                actualFrame = .zero
            }
            if let screenId, let screenDescriptor {
                print("  Window \(window.windowId) (\(type)) on \(screenDescriptor.localizedName) [\(screenId)]: \(actualFrame)")
            } else {
                print("  Window \(window.windowId) (\(type)) on unknown screen: \(actualFrame)")
            }
        }
        print("")
    }

    // MARK: - JSON API for Socket Server

    func addZoneJSON() -> [String: Any] {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            return ["error": "Failed to add zone (max 3 zones)"]
        }
        syncWindowsToZones()
        return [
            "screen_display_id": screenId,
            "screen_name": context.descriptor.localizedName,
            "zone_index": newZone.index,
            "zone_count": context.zoneController.allZones.count
        ]
    }

    func removeZoneJSON(at index: Int) -> [String: Any] {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId],
              let removalResult = performRemoveZone(at: index, on: screenId, announce: false, context: context) else {
            return ["error": "Failed to remove zone \(index)"]
        }

        var response: [String: Any] = [
            "screen_display_id": screenId,
            "screen_name": context.descriptor.localizedName,
            "removed_index": index,
            "zone_count": context.zoneController.allZones.count,
            "removed_window_id": removalResult.removedWindowId as Any
        ]

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            response["reassigned_window_id"] = managed.windowId
            response["reassigned_zone_index"] = managed.zoneIndex as Any
            response["reassigned_screen_display_id"] = managed.screenDisplayId as Any
        }

        return response
    }

    func resizeZoneJSON(at index: Int, frame: CGRect) -> [String: Any] {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            return ["error": "Active screen not available"]
        }

        guard let zone = context.zoneController.zone(at: index) else {
            return ["error": "Zone \(index) not found on \(context.descriptor.localizedName)"]
        }

        guard zone.isEmpty else {
            return ["error": "Zone \(index) is occupied; minimize or close its window before resizing."]
        }

        guard context.zoneController.resizeZone(at: index, to: frame) else {
            return ["error": "Failed to resize zone \(index)"]
        }

        syncWindowsToZones()

        guard let updatedZone = context.zoneController.zone(at: index) else {
            return ["error": "Zone \(index) unavailable after resize"]
        }

        return [
            "screen_display_id": screenId,
            "screen_name": context.descriptor.localizedName,
            "zone_index": updatedZone.index,
            "frame": [
                "x": updatedZone.frame.origin.x,
                "y": updatedZone.frame.origin.y,
                "width": updatedZone.frame.width,
                "height": updatedZone.frame.height
            ],
            "zone_count": context.zoneController.allZones.count
        ]
    }

    func createWindowJSON() -> [String: Any] {
        let managed = windowController.createTestWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        placeNewWindow(managed)
        return [
            "window_id": managed.windowId,
            "zone_index": managed.zoneIndex as Any,
            "screen_display_id": managed.screenDisplayId as Any
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
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            return [
                "window_id": managed.windowId,
                "zone_index": zoneIndex,
                "screen_display_id": screenId,
                "screen_name": screenContexts[screenId]?.descriptor.localizedName as Any,
                "message": "Already managed"
            ]
        }

        placeNewWindow(managed)

        return [
            "window_id": managed.windowId,
            "zone_index": managed.zoneIndex as Any,
            "screen_display_id": managed.screenDisplayId as Any
        ]
    }

    func closeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        removeWindowFromAllZones(windowId: windowId)
        windowController.closeWindow(managed)
        syncWindowsToZones()

        return ["window_id": windowId]
    }

    func minimizeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        windowController.minimizeWindow(managed)
        removeWindowFromAllZones(windowId: windowId)
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
            "zone_index": managed.zoneIndex as Any,
            "screen_display_id": managed.screenDisplayId as Any
        ]
    }

    func listZonesJSON() -> [String: Any] {
        let zones = screenOrder.flatMap { screenId -> [[String: Any]] in
            guard let context = screenContexts[screenId] else { return [] }
            return context.zoneController.allZones.map { zone in
                [
                    "screen_display_id": screenId,
                    "screen_name": context.descriptor.localizedName,
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
        }
        return ["zones": zones]
    }

    func relayoutJSON() -> [String: Any] {
        for context in screenContexts.values {
            context.zoneController.relayout()
        }
        syncWindowsToZones()
        let screenSummaries = screenOrder.compactMap { screenId -> [String: Any]? in
            guard let context = screenContexts[screenId] else { return nil }
            return [
                "screen_display_id": screenId,
                "screen_name": context.descriptor.localizedName,
                "zone_count": context.zoneController.allZones.count
            ]
        }
        return ["screens": screenSummaries]
    }

    func windowInfoJSON(windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        let type: String
        if managed.isPlaceholder {
            type = "placeholder"
        } else {
            switch managed.backing {
            case .appKit:
                type = "test"
            case .accessibility:
                type = "external"
            }
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
            descriptor(for: id)
        }
        let actualFrame: CGRect
        if let screenDescriptor {
            actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: screenDescriptor)
        } else if let fallback = windowController.actualFrameInScreenCoordinates(for: managed) {
            actualFrame = fallback
        } else {
            actualFrame = .zero
        }

        var result: [String: Any] = [
            "window_id": windowId,
            "type": type,
            "is_placeholder": managed.isPlaceholder,
            "zone_index": managed.zoneIndex as Any,
            "actual_frame": [
                "x": actualFrame.origin.x,
                "y": actualFrame.origin.y,
                "width": actualFrame.width,
                "height": actualFrame.height
            ]
        ]

        if let screenId, let screenDescriptor {
            result["screen_display_id"] = screenId
            result["screen_name"] = screenDescriptor.localizedName
        }

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex) {
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
            let type: String
            if window.isPlaceholder {
                type = "placeholder"
            } else {
                switch window.backing {
                case .appKit:
                    type = "test"
                case .accessibility:
                    type = "external"
                }
            }
            let screenId = window.screenDisplayId ?? detectScreenId(for: window)
            let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
                descriptor(for: id)
            }
            let actualFrame: CGRect
            if let screenDescriptor {
                actualFrame = windowController.actualFrameInScreenCoordinates(for: window, on: screenDescriptor)
            } else if let fallback = windowController.actualFrameInScreenCoordinates(for: window) {
                actualFrame = fallback
            } else {
                actualFrame = .zero
            }
            return [
                "window_id": window.windowId,
                "type": type,
                "is_placeholder": window.isPlaceholder,
                "screen_display_id": screenId as Any,
                "screen_name": screenDescriptor?.localizedName as Any,
                "frame": [
                    "x": actualFrame.origin.x,
                    "y": actualFrame.origin.y,
                    "width": actualFrame.width,
                    "height": actualFrame.height
                ]
            ]
        }
        return ["windows": frames]
    }
}
