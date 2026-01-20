import Foundation
import AppKit
import ApplicationServices

// Bridge to the private AX API that reveals a window's CGWindowID. There is no public
// Accessibility attribute that exposes this identifier, so we must rely on this symbol.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
let axCloseAction: CFString = "AXClose" as CFString
let axDestroyedNotification = kAXUIElementDestroyedNotification as String
let axMiniaturizedNotification = kAXWindowMiniaturizedNotification as String
let axDeminiaturizedNotification = kAXWindowDeminiaturizedNotification as String
let axMovedNotificationName = kAXMovedNotification as String
let axResizedNotificationName = kAXResizedNotification as String
let axWindowCreatedNotificationName = kAXWindowCreatedNotification as String
let axMainWindowChangedNotificationName = kAXMainWindowChangedNotification as String

struct DragCandidate {
    let windowId: Int
    let originFrame: CGRect
}

struct AccessibilityElementKey: Hashable {
    let element: AXUIElement

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    static func == (lhs: AccessibilityElementKey, rhs: AccessibilityElementKey) -> Bool {
        return CFEqual(lhs.element, rhs.element)
    }
}

/// Encapsulates AppKit window creation and manipulation
class WindowController {
    enum HideReason {
        case zoneExcluded
        case replacedByOccupant
        case inactiveZone
    }

    internal let windowRegistry = ManagedWindowRegistry()
    internal let accessibilityWatcher: AccessibilityWatcher
    internal var externalWindows: [ExternalWindowIdentifier: ManagedWindow] = [:]
    internal var externalWindowsByElement: [AccessibilityElementKey: ManagedWindow] = [:]
    internal var programmaticUpdateWindowIds: Set<Int> = []
    internal var programmaticUpdateWorkItems: [Int: DispatchWorkItem] = [:]
    internal var pendingAccessibilityFrameRetryWindowIds: Set<Int> = []
    internal var accessibilityFrameRetryWorkItems: [Int: DispatchWorkItem] = [:]
    internal var ignoredBundleIdentifiers: Set<String>
    internal var accessibilityPermissionWarningShown = false
    weak var delegate: WindowControllerDelegate?
    internal var currentDraggingWindowId: Int?
    internal var mouseUpMonitor: Any?
    internal var mouseUpGlobalMonitor: Any?
    internal let primaryScreenBounds: CGRect
    internal var applicationExceptionPolicy: ApplicationExceptionPolicy
    internal var dragCandidate: DragCandidate?

    // Require at least a few pixels of movement (with the button still down)
    // before turning an AXMoved burst into a real drag begin event.
    internal let dragActivationDistance: CGFloat = 6

    /// Tracks the last time each window was activated (for launcher recency ordering)
    internal var windowLastActiveTime: [Int: Date] = [:]

    struct CaptureResult {
        let windows: [ManagedWindow]
        let needsRetry: Bool
    }

    init(
        ignoredBundleIdentifiers: Set<String> = [],
        primaryScreenBounds: CGRect,
        applicationExceptionPolicy: ApplicationExceptionPolicy = .empty
    ) {
        self.accessibilityWatcher = AccessibilityWatcher(
            windowNotifications: AccessibilityNotificationCatalog.windowNotifications,
            applicationNotifications: AccessibilityNotificationCatalog.applicationNotifications
        )
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        self.primaryScreenBounds = primaryScreenBounds
        self.applicationExceptionPolicy = applicationExceptionPolicy
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.handleMouseUp()
            return event
        }
        accessibilityWatcher.delegate = self
    }

    deinit {
        accessibilityWatcher.cancelAllObservers()
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseUpGlobalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    internal func updateMouseUpGlobalMonitorInstallation() {
        let needsGlobalMonitor = dragCandidate != nil || currentDraggingWindowId != nil
        if needsGlobalMonitor {
            installMouseUpGlobalMonitorIfNeeded()
        } else {
            tearDownMouseUpGlobalMonitorIfNeeded()
        }
    }

    private func installMouseUpGlobalMonitorIfNeeded() {
        guard mouseUpGlobalMonitor == nil else {
            return
        }

        mouseUpGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.handleMouseUp()
        }
    }

    private func tearDownMouseUpGlobalMonitorIfNeeded() {
        guard let monitor = mouseUpGlobalMonitor else {
            return
        }

        NSEvent.removeMonitor(monitor)
        mouseUpGlobalMonitor = nil
    }

    /// Cancel all scheduled accessibility frame retries and clear their bookkeeping.
    func cancelAllAccessibilityFrameRetries() {
        for (_, workItem) in accessibilityFrameRetryWorkItems {
            workItem.cancel()
        }
        let count = accessibilityFrameRetryWorkItems.count
        accessibilityFrameRetryWorkItems.removeAll()
        pendingAccessibilityFrameRetryWindowIds.removeAll()
        if count > 0 {
            Logger.debug("Cancelled \(count) pending accessibility frame retry/retries")
        }
    }

    func pruneDestroyedExternalWindows() -> [Int] {
        pruneDestroyedWindows(pidFilter: nil)
    }

    /// Detect and prune external windows for a specific PID whose accessibility elements have been destroyed.
    /// - Parameter pid: The process identifier to check windows for.
    /// - Returns: The window identifiers that were removed.
    func pruneDestroyedWindowsForPid(_ pid: pid_t) -> [Int] {
        return pruneDestroyedWindows(pidFilter: pid)
    }

    /// Remove all managed windows for a terminated process.
    /// - Parameter pid: The process identifier whose windows should be discarded.
    /// - Returns: The window identifiers that were removed.
    func removeAllWindows(forPid pid: pid_t) -> [Int] {
        let windowsForPid = windowRegistry.allWindows.filter { $0.backing.pid == pid }

        guard !windowsForPid.isEmpty else {
            return []
        }

        let windowIds = windowsForPid.map { $0.windowId }

        for managed in windowsForPid {
            let windowId = managed.windowId
            Logger.debug("Removing external window \(windowId) for terminated pid \(pid)")
            removeAccessibilityTracking(for: managed)
            externalWindows.removeValue(forKey: managed.externalIdentifier)
            windowRegistry.removeWindow(withId: windowId)
            programmaticUpdateWindowIds.remove(windowId)
            programmaticUpdateWorkItems[windowId]?.cancel()
            programmaticUpdateWorkItems.removeValue(forKey: windowId)
            if currentDraggingWindowId == windowId {
                currentDraggingWindowId = nil
            }
            if dragCandidate?.windowId == windowId {
                dragCandidate = nil
            }
        }

        updateMouseUpGlobalMonitorInstallation()

        // Once all managed windows for this pid are removed due to process termination,
        // tear down the associated AX observer as well.
        accessibilityWatcher.removeObserver(for: pid)

        return windowIds
    }

    private func pruneDestroyedWindows(pidFilter: pid_t?) -> [Int] {
        guard let snapshot = makeWindowServerSnapshot(pidFilter: pidFilter) else {
            return []
        }

        var stale: [(Int, ManagedWindow, String)] = []

        for managed in windowRegistry.allWindows {
            let windowId = managed.windowId
            let windowPid = managed.backing.pid
            let cgWindowId = managed.backing.cgWindowId

            if let pidFilter, windowPid != pidFilter {
                continue
            }

            if !snapshot.contains(pid: windowPid, cgWindowId: cgWindowId) {
                stale.append((windowId, managed, "missing-from-cgwindowlist"))
                continue
            }

            if !isAccessibilityElementAlive(managed) {
                stale.append((windowId, managed, "ax-element-invalid"))
            }
        }

        guard !stale.isEmpty else {
            return []
        }

        var removedWindowIds: [Int] = []
        for (windowId, managed, reason) in stale {
            let pid = managed.backing.pid
            Logger.debug("Detected destroyed external window \(windowId) pid \(pid) (reason: \(reason)); pruning")
            removeAccessibilityTracking(for: managed)
            windowRegistry.removeWindow(withId: windowId)
            externalWindows.removeValue(forKey: managed.externalIdentifier)
            removedWindowIds.append(windowId)
            Logger.debug("Pruned destroyed external window \(windowId)")
        }

        return removedWindowIds
    }

    private enum WindowServerSnapshot {
        case global(Set<ExternalWindowIdentifier>)
        case pid(pid_t, Set<Int>)

        func contains(pid: pid_t, cgWindowId: Int) -> Bool {
            switch self {
            case .global(let identifiers):
                return identifiers.contains(ExternalWindowIdentifier(pid: pid, cgWindowId: cgWindowId))
            case .pid(let filterPid, let cgWindowIds):
                guard pid == filterPid else {
                    return false
                }
                return cgWindowIds.contains(cgWindowId)
            }
        }
    }

    private func makeWindowServerSnapshot(pidFilter: pid_t?) -> WindowServerSnapshot? {
        if let pidFilter {
            let numbers = getCGWindowIdsFromWindowServer(forPid: pidFilter)
            return .pid(pidFilter, numbers)
        }

        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var identifiers = Set<ExternalWindowIdentifier>()
        for windowInfo in windowList {
            if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
               let cgWindowId = windowInfo[kCGWindowNumber as String] as? Int {
                identifiers.insert(ExternalWindowIdentifier(pid: ownerPID, cgWindowId: cgWindowId))
            }
        }

        return .global(identifiers)
    }

    /// Query the window server for actual CGWindowIDs for a given PID.
    /// This is the ground truth source for which windows exist.
    private func getCGWindowIdsFromWindowServer(forPid pid: pid_t) -> Set<Int> {
        var cgWindowIds = Set<Int>()

        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return cgWindowIds
        }

        for windowInfo in windowList {
            if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
               ownerPID == pid,
               let cgWindowId = windowInfo[kCGWindowNumber as String] as? Int {
                cgWindowIds.insert(cgWindowId)
            }
        }

        return cgWindowIds
    }

    private func isAccessibilityElementAlive(_ managed: ManagedWindow) -> Bool {
        let element = managed.backing.element

        func statusIndicatesInvalid(_ status: AXError) -> Bool {
            switch status {
            case .invalidUIElement, .cannotComplete, .illegalArgument:
                return true
            default:
                return false
            }
        }

        func attributeAppearsValid(_ attribute: CFString) -> Bool {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute, &value)
            if status == .success || status == .noValue || status == .attributeUnsupported {
                return true
            }
            if statusIndicatesInvalid(status) {
                Logger.debug("Accessibility attribute \(attribute as String) for window \(managed.windowId) returned AX error \(status.rawValue)")
                return false
            }
            Logger.debug("Accessibility attribute \(attribute as String) for window \(managed.windowId) returned AX status \(status.rawValue); treating as still alive")
            return true
        }

        let roleAlive = attributeAppearsValid(kAXRoleAttribute as CFString)
        if !roleAlive {
            return false
        }

        return attributeAppearsValid(kAXPositionAttribute as CFString)
    }

    /// Get the actual frame of a window in screen-local coordinates
    func actualFrameInScreenCoordinates(for managedWindow: ManagedWindow, on screen: ScreenDescriptor) -> CGRect {
        let element = managedWindow.backing.element
        guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
              let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
            return .zero
        }
        let accessibilityFrame = CGRect(origin: position, size: size)
        return screen.accessibilityToScreen(accessibilityFrame)
    }

    /// Convenience helper that resolves the screen descriptor via the delegate.
    func actualFrameInScreenCoordinates(for managedWindow: ManagedWindow) -> CGRect? {
        guard let screenId = managedWindow.screenDisplayId,
              let descriptor = delegate?.screenDescriptor(for: screenId) else {
            return nil
        }
        return actualFrameInScreenCoordinates(for: managedWindow, on: descriptor)
    }

    /// Get the actual frame expressed in accessibility coordinates (origin at primary display top-left).
    func actualFrameInAccessibilityCoordinates(for managedWindow: ManagedWindow) -> CGRect? {
        let element = managedWindow.backing.element
        guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
              let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// Get all managed windows
    var allWindows: [ManagedWindow] {
        return windowRegistry.allWindows
    }

    // MARK: - Window Activity Tracking (for Launcher recency)

    /// Record that a window was activated (for launcher recency ordering)
    func recordWindowActivity(windowId: Int) {
        windowLastActiveTime[windowId] = Date()
    }

    /// Get the last active time for a window (for launcher recency ordering)
    func lastActiveTime(for windowId: Int) -> Date? {
        windowLastActiveTime[windowId]
    }
}

// Helper methods for ManagedWindow to access coordinate conversion
extension ManagedWindow {
    /// Helper methods to copy AX values - made internal for use by WindowController
    static func copyCGPointValue(element: AXUIElement, attribute: CFString) -> CGPoint? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard status == .success, let rawValue else {
            return nil
        }
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)

        var point = CGPoint.zero
        guard AXValueGetType(axValue) == AXValueType(rawValue: kAXValueCGPointType),
              AXValueGetValue(axValue, AXValueType(rawValue: kAXValueCGPointType)!, &point) else {
            return nil
        }
        return point
    }

    static func copyCGSizeValue(element: AXUIElement, attribute: CFString) -> CGSize? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard status == .success, let rawValue else {
            return nil
        }
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)

        var size = CGSize.zero
        guard AXValueGetType(axValue) == AXValueType(rawValue: kAXValueCGSizeType),
              AXValueGetValue(axValue, AXValueType(rawValue: kAXValueCGSizeType)!, &size) else {
            return nil
        }
        return size
    }
}

/// Delegate protocol for window controller events
protocol WindowControllerDelegate: AnyObject {
    func windowWillClose(windowId: Int)
    func windowDidMiniaturize(windowId: Int)
    func windowDidDeminiaturize(windowId: Int)
    func windowFocusChanged(pid: pid_t, focusedWindowId: Int?)
    func windowManualResizeDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect)
    func windowManualMoveDidBegin(windowId: Int, frame: CGRect)
    func windowManualMoveDidUpdate(windowId: Int, frame: CGRect)
    func windowManualMoveDidEnd(windowId: Int, finalFrame: CGRect)
    func windowManualMoveDidAbort(windowId: Int)  // Drag died because the source window vanished mid-gesture.
    func screenDescriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?
    func windowController(_ controller: WindowController, didCaptureExternalWindow window: ManagedWindow)
    func windowCreationFailedRetryNeeded(forPid pid: pid_t)
    func debugTargetedZoneDescription() -> String?
    func isWindowManagedByActiveFit(windowId: Int) -> Bool
    func isZoneResizeDragInProgress() -> Bool
}
