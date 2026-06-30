import Foundation
import AppKit
import ApplicationServices
import OSLog

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
    /// Most recent moment each window was confirmed alive via a successful AX liveness check.
    /// Used to skip redundant per-sync AX reads when the same window was just verified.
    internal var lastConfirmedAliveAt: [Int: Date] = [:]
    /// Window-liveness AX check is skipped if a positive result was recorded within this window.
    /// CGWindowList removal is the primary destruction signal and runs unconditionally on every
    /// prune; the AX check is a safety net for the rare "still in window list but AX-element
    /// invalid" case. Empirical traces show this safety net almost never fires, so the TTL is
    /// sized generously: 5s eliminates the bulk of redundant AX reads while bounding the
    /// worst-case detection delay for that edge case to 5s.
    internal static let aliveCheckCacheTTL: TimeInterval = 5.0
    internal static let frameRetryDelays: [TimeInterval] = [0.25, 0.5, 1.0, 3.0]
    internal var accessibilityFrameRetryStates: [Int: FrameRetryState] = [:]
    internal var nextAccessibilityFrameRetryChainId: UInt64 = 1
    internal var ignoredBundleIdentifiers: Set<String>
    internal var nativeTabHandlingDisabled: Bool
    internal var accessibilityPermissionWarningShown = false
    weak var delegate: WindowControllerDelegate?
    internal var currentDraggingWindowId: Int?
    internal var mouseUpMonitor: Any?
    internal var mouseUpGlobalMonitor: Any?
    /// Primary display bounds for Cocoa<->Accessibility conversion (cursor/drag mapping).
    /// Refreshed by AppController on screen-topology changes so it tracks resolution changes.
    internal var primaryScreenBounds: CGRect
    internal var applicationExceptionPolicy: ApplicationExceptionPolicy
    internal var dragCandidate: DragCandidate?
    /// Most recent moment each window was moved by its own application — a non-programmatic move
    /// that is not a recognized Zonogy manual drag. Focus-driven frame reasserts consult
    /// `isExternallyMovingRecently(windowId:)` so they do not immediately fight that app move.
    internal var lastExternalMoveByWindowId: [Int: Date] = [:]
    internal var pendingPrunedWindows = PendingPrunedWindowStore()
    /// Window ids whose next activity record should be skipped because they were restored
    /// from deferred-prune state and should keep their prior recency ordering.
    internal var restoredPendingPruneActivitySkipWindowIds: Set<Int> = []
    /// Original placement targets for windows restored from deferred-prune state.
    internal var restoredPendingPruneDestinationsByWindowId: [Int: PendingPrunedWindowDestination] = [:]
    /// Serial background queue for dispatching AX writes during live zone resize drags.
    /// Keeps the main thread free while window position/size updates proceed in order.
    internal let liveResizeAXQueue = DispatchQueue(
        label: "com.zonogy.live-resize-ax",
        qos: .userInteractive
    )
    /// Pending AX write closures accumulated by `moveWindowForLiveResize`,
    /// dispatched as a single batch by `flushLiveResizeWrites()`.
    internal var pendingLiveResizeWrites: [() -> Void] = []
    /// True when the live-resize AX queue has a batch still in flight (main-thread only).
    internal var isLiveResizeAXBatchInFlight = false
    /// True when the live-resize AX queue has pending work, used for frame-skipping.
    internal var isLiveResizeAXQueueBusy: Bool { isLiveResizeAXBatchInFlight }

    // Require at least a few pixels of movement (with the button still down)
    // before turning an AXMoved burst into a real drag begin event.
    internal let dragActivationDistance: CGFloat = 6

    /// How long after an application-driven move (see `lastExternalMoveByWindowId`) focus-driven
    /// frame reasserts stay suppressed for that window.
    internal static let externalMoveReassertSuppressionWindow: TimeInterval = 0.3

    /// Tracks the last time each window was activated for shared managed-window recency ordering.
    internal var windowLastActiveTime: [Int: Date] = [:]

    struct CaptureResult {
        let windows: [ManagedWindow]
        let needsRetry: Bool
    }

    init(
        ignoredBundleIdentifiers: Set<String> = [],
        nativeTabHandlingDisabled: Bool = false,
        primaryScreenBounds: CGRect,
        applicationExceptionPolicy: ApplicationExceptionPolicy = .empty
    ) {
        self.accessibilityWatcher = AccessibilityWatcher(
            windowNotifications: AccessibilityNotificationCatalog.windowNotifications,
            applicationNotifications: AccessibilityNotificationCatalog.applicationNotifications
        )
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        self.nativeTabHandlingDisabled = nativeTabHandlingDisabled
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

    func hasFrameRetryPending(for windowId: Int) -> Bool {
        accessibilityFrameRetryStates[windowId] != nil
    }

    /// Cancel all scheduled accessibility frame retries and clear their bookkeeping.
    func cancelAllAccessibilityFrameRetries(reason: String? = nil) {
        let count = accessibilityFrameRetryStates.count
        for (_, var state) in accessibilityFrameRetryStates {
            state.cancel()
        }
        accessibilityFrameRetryStates.removeAll()
        if count > 0 {
            if let reason {
                Logger.debug("Cancelled \(count) pending accessibility frame retry/retries (reason: \(reason))")
            } else {
                Logger.debug("Cancelled \(count) pending accessibility frame retry/retries")
            }
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
        let hadPendingPrunedWindows = pendingPrunedWindows.hasEntries(forPid: pid)

        discardPendingPrunedWindows(forPid: pid, reason: "pid-removal")

        guard !windowsForPid.isEmpty else {
            if hadPendingPrunedWindows {
                accessibilityWatcher.removeObserver(for: pid)
            }
            return []
        }

        let windowIds = windowsForPid.map { $0.windowId }

        for managed in windowsForPid {
            let windowId = managed.windowId
            Logger.debug("Removing external window \(windowId) for terminated pid \(pid)")
            windowLastActiveTime.removeValue(forKey: windowId)
            removeManagedWindowFromLiveTracking(managed)
        }

        // Once all managed windows for this pid are removed due to process termination,
        // tear down the associated AX observer as well.
        accessibilityWatcher.removeObserver(for: pid)

        return windowIds
    }

    private func pruneDestroyedWindows(pidFilter: pid_t?) -> [Int] {
        guard let snapshot = makeWindowServerSnapshot(pidFilter: pidFilter) else {
            return []
        }

        let signpostState = ZonogySignposts.pointsOfInterest.beginInterval("PruneDestroyed")
        var considered = 0
        var aliveCacheHits = 0
        var aliveCacheMisses = 0
        var staleByCGWindowList = 0
        var staleByAX = 0
        var parkedSkips = 0
        defer {
            ZonogySignposts.pointsOfInterest.endInterval(
                "PruneDestroyed",
                signpostState,
                "considered=\(considered, privacy: .public) cacheHits=\(aliveCacheHits, privacy: .public) cacheMisses=\(aliveCacheMisses, privacy: .public) parkedSkips=\(parkedSkips, privacy: .public) staleCG=\(staleByCGWindowList, privacy: .public) staleAX=\(staleByAX, privacy: .public)"
            )
        }

        var stale: [(Int, ManagedWindow, String)] = []
        var pidsNeedingNativeTabValidation: Set<pid_t> = []
        let now = Date()

        func deferWindowServerMissToPidValidationIfNeeded(
            _ managed: ManagedWindow,
            reason: String
        ) -> Bool {
            // Global WindowServer snapshots can be transiently incomplete; defer sibling
            // selection to a PID-scoped pass before treating this as a closed native tab.
            guard pidFilter == nil,
                  managed.isPlacedInZone,
                  !nativeTabHandlingDisabled else {
                return false
            }

            pidsNeedingNativeTabValidation.insert(managed.backing.pid)
            Logger.debug(
                "Deferring stale placed window \(managed.windowId) pid \(managed.backing.pid) (reason: \(reason)) to PID-scoped native-tab validation"
            )
            return true
        }

        for managed in windowRegistry.allWindows {
            let windowId = managed.windowId
            let windowPid = managed.backing.pid
            let cgWindowId = managed.backing.cgWindowId

            if let pidFilter, windowPid != pidFilter {
                continue
            }

            considered += 1

            if !snapshot.contains(pid: windowPid, cgWindowId: cgWindowId) {
                staleByCGWindowList += 1
                if deferWindowServerMissToPidValidationIfNeeded(
                    managed,
                    reason: "missing-from-cgwindowlist"
                ) {
                    continue
                }
                stale.append((windowId, managed, "missing-from-cgwindowlist"))
                continue
            }

            // Don't fire AX queries at parked windows (minimized or otherwise unplaced).
            // Parked windows aren't in zones, so we're not actively using their AX state,
            // and the target app may be App-Napping — an AX read here forces a wake-up
            // for no observable user benefit. CGWindowList already covers the destruction
            // path for parked windows; the AX safety-net only mattered for the rare
            // "still listed but AX-element invalid" edge case, which is even rarer for
            // a window the user has actively parked.
            //
            // Checked before the cache-hit branch so the `parkedSkips` counter cleanly
            // measures the skip-on-parked rule independent of cache state.
            if !managed.isPlacedInZone {
                parkedSkips += 1
                continue
            }

            if let lastAlive = lastConfirmedAliveAt[windowId],
               now.timeIntervalSince(lastAlive) < Self.aliveCheckCacheTTL {
                aliveCacheHits += 1
                continue
            }

            aliveCacheMisses += 1
            if !isAccessibilityElementAlive(managed) {
                lastConfirmedAliveAt.removeValue(forKey: windowId)
                staleByAX += 1
                // Native-tab close deferral is intentionally limited to WindowServer misses.
                // If the window is still listed but AX is invalid, handle it through the
                // ordinary deferred-prune path instead of treating it as a tab-close signal.
                stale.append((windowId, managed, "ax-element-invalid"))
            } else {
                lastConfirmedAliveAt[windowId] = now
            }
        }

        for pid in pidsNeedingNativeTabValidation.sorted() {
            delegate?.windowController(self, didDeferNativeTabPruneForPidValidation: pid)
        }

        guard !stale.isEmpty else {
            return []
        }

        // Native-tab close-rebind is allowed for per-pid validation. The global sweep defers
        // eligible placed candidates to PID validation above; remaining stale windows are handled
        // directly without sibling selection.
        let allowNativeTabRebind = pidFilter != nil
        var removedWindowIds: [Int] = []
        for (windowId, managed, reason) in stale {
            let pid = managed.backing.pid
            Logger.debug("Detected destroyed external window \(windowId) pid \(pid) (reason: \(reason)); evaluating for deferred prune")
            if stagePendingPrunedWindow(managed, reason: reason, allowNativeTabRebind: allowNativeTabRebind) {
                removedWindowIds.append(windowId)
                Logger.debug("Deferred-prune staged external window \(windowId)")
            } else {
                Logger.debug("Kept external window \(windowId) (rebound to surviving native-tab sibling) instead of pruning")
            }
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
            let status = AXCall.copyAttribute(element, attribute, &value)
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

    // MARK: - Window Activity Tracking (shared recency ordering)

    /// Record that a window was activated for shared managed-window recency ordering.
    func recordWindowActivity(windowId: Int, at timestamp: Date = Date()) {
        if restoredPendingPruneActivitySkipWindowIds.remove(windowId) != nil {
            Logger.debug("Skipping first activity record for restored deferred-prune window \(windowId)")
            return
        }
        windowLastActiveTime[windowId] = timestamp
    }

    /// Get the last active time for a window in shared managed-window recency ordering.
    func lastActiveTime(for windowId: Int) -> Date? {
        windowLastActiveTime[windowId]
    }

    /// Returns true if the left window should sort ahead of the right window in shared recency order.
    func isWindowMoreRecent(windowId lhsId: Int, than rhsId: Int) -> Bool {
        ManagedWindowRecencyOrder.isMoreRecent(
            windowId: lhsId,
            lastActiveTime: lastActiveTime(for: lhsId),
            than: rhsId,
            otherLastActiveTime: lastActiveTime(for: rhsId)
        )
    }

    /// Returns all managed windows ordered by shared CmdTab/Launcher recency semantics.
    func allWindowsOrderedByRecency() -> [ManagedWindow] {
        allWindows.sorted { lhs, rhs in
            isWindowMoreRecent(windowId: lhs.windowId, than: rhs.windowId)
        }
    }

    /// Returns the managed window currently first in shared CmdTab/Launcher recency order.
    func mostRecentManagedWindowId() -> Int? {
        allWindows.reduce(nil) { currentBest, window in
            guard let currentBest else {
                return window.windowId
            }
            return isWindowMoreRecent(windowId: window.windowId, than: currentBest)
                ? window.windowId
                : currentBest
        }
    }

    /// Returns true if the given window currently leads shared CmdTab/Launcher recency order.
    func isMostRecentlyActive(windowId: Int) -> Bool {
        mostRecentManagedWindowId() == windowId
    }
}

// Helper methods for ManagedWindow to access coordinate conversion
extension ManagedWindow {
    /// Read an element's current frame (position + size) in accessibility coordinates
    /// (primary-display top-left origin), or nil if either attribute is unavailable.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
              let size = copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// Helper methods to copy AX values - made internal for use by WindowController
    static func copyCGPointValue(element: AXUIElement, attribute: CFString) -> CGPoint? {
        var rawValue: CFTypeRef?
        let status = AXCall.copyAttribute(element, attribute, &rawValue)
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
        let status = AXCall.copyAttribute(element, attribute, &rawValue)
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

internal struct FrameRetryState {
    let chainId: UInt64
    var attempt: Int = 0
    var targetScreenFrame: CGRect
    var workItem: DispatchWorkItem?

    mutating func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

/// Delegate protocol for window controller events
protocol WindowControllerDelegate: AnyObject {
    func windowWillClose(windowId: Int)
    func windowDidMiniaturize(windowId: Int)
    func windowDidDeminiaturize(windowId: Int)
    func windowDidAdoptNativeTabOnDeminiaturize(originalWindowId: Int, adoptedWindowId: Int)
    /// Called after a placed native-tab source window is removed because its backing was adopted
    /// by another placed same-process managed window.
    func windowController(_ controller: WindowController, didCollapseNativeTabSourceWindow sourceWindowId: Int, into destinationWindowId: Int)
    func windowDidResize(windowId: Int)
    func windowElementDidCreate(element: AXUIElement, pid: pid_t)
    func windowElementDidResize(element: AXUIElement, pid: pid_t)
    func windowElementDidClose(element: AXUIElement, pid: pid_t)
    func windowFocusChanged(pid: pid_t, focusedWindowId: Int?)
    func windowManualResizeDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect)
    func windowManualMoveDidBegin(windowId: Int, frame: CGRect)
    func windowManualMoveDidUpdate(windowId: Int, frame: CGRect)
    func windowManualMoveDidEnd(windowId: Int, finalFrame: CGRect)
    func windowManualMoveDidAbort(windowId: Int)  // Drag died because the source window vanished mid-gesture.
    func screenDescriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?
    func windowController(_ controller: WindowController, didCaptureExternalWindow window: ManagedWindow)
    /// Called when pending-prune entries are permanently discarded (window truly gone).
    /// Staged windows restored via deferred-prune matching do NOT fire this callback.
    func windowController(_ controller: WindowController, didDiscardPendingPrunedWindowIds windowIds: [Int], reason: String)
    /// Called when a global sweep sees a placed native-tab candidate missing from WindowServer.
    /// The delegate should run PID-scoped validation so sibling selection uses a narrower snapshot.
    func windowController(_ controller: WindowController, didDeferNativeTabPruneForPidValidation pid: pid_t)
    func windowCreationFailedRetryNeeded(forPid pid: pid_t)
    func debugTargetedZoneDescription() -> String?
    func isWindowManagedByActiveFit(windowId: Int) -> Bool
    func isZoneResizeDragInProgress() -> Bool
    func frameRetryDidSettle(windowId: Int)
}
