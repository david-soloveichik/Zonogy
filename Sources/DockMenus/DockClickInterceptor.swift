import Foundation
import ApplicationServices
import AppKit

/// Notified when a left-click is intercepted on an app in the Dock.
protocol DockClickInterceptorDelegate: AnyObject {
    /// Called when a click on an app's Dock icon was intercepted.
    /// - Parameters:
    ///   - interceptor: The interceptor instance.
    ///   - appURL: The URL of the clicked application bundle.
    ///   - itemFrame: The accessibility frame of the clicked Dock item (origin at top-left of primary screen).
    ///   - dockItemElement: The accessibility element of the clicked Dock item (for simulating press if needed).
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didInterceptClickOnApp appURL: URL, itemFrame: CGRect, dockItemElement: AXUIElement)

    /// Called when a drag is detected on a running app's Dock icon and Zonogy intends to intercept it.
    /// Return true to accept handling the drag (subsequent drag events will be swallowed).
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didBeginDragOnApp appURL: URL, itemFrame: CGRect, cursorPoint: CGPoint) -> Bool

    /// Called when a drag is detected on a non-running app's Dock icon.
    /// Return true to accept handling the drag (subsequent drag events will be swallowed).
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didBeginDragOnNonRunningApp appURL: URL, itemFrame: CGRect, cursorPoint: CGPoint) -> Bool

    /// Called repeatedly during an intercepted drag as the cursor moves.
    func dockClickInterceptorDidUpdateDrag(_ interceptor: DockClickInterceptor, cursorPoint: CGPoint)

    /// Called when an intercepted drag ends (mouse up).
    func dockClickInterceptorDidEndDrag(_ interceptor: DockClickInterceptor, cursorPoint: CGPoint)
}

/// Intercepts global left-clicks within the Dock's AXList frame.
/// Performance-critical: exits as fast as possible when the click is outside the frame.
///
/// Intercepts clicks on application Dock items (AXApplicationDockItem), both running and non-running.
/// Clicks on folders, files, Launchpad, Trash pass through.
/// Drags are detected; eligible app-item drags are intercepted and routed into Zonogy.
final class DockClickInterceptor {
    private enum Constants {
        static let eventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        static let dockBundleIdentifier = "com.apple.dock"
        /// Movement threshold in pixels to initiate a Dock drag interception.
        static let dragThreshold: CGFloat = 8.0
    }

    weak var delegate: DockClickInterceptorDelegate?

    /// Called when a click occurs in the Dock frame but no Dock element is found (Dock is hidden).
    var onDockNotFound: (() -> Void)?

    /// The frame to intercept clicks within (Accessibility coordinates: origin at top-left of primary screen).
    private var interceptFrame: CGRect?

    /// Whether the Dock is currently considered visible.
    private var isDockVisible = false

    /// Cached Dock PID for accessibility queries.
    private var dockPid: pid_t?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Tracks a pending click that may be intercepted on mouse-up.
    private var pendingClick: PendingClick?

    private enum DragState {
        case none
        case intercepted
        case unhandled
    }

    private enum TopmostDockHit {
        case dockApp(ClickedAppResult)
        case nonDock
        case unavailable
    }

    /// State for tracking a potential click that will be intercepted on mouse-up.
    private struct PendingClick {
        let downLocation: CGPoint
        let appURL: URL
        let itemFrame: CGRect
        let isRunning: Bool
        let dockItemElement: AXUIElement
        var dragState: DragState = .none
    }

    func updateFrame(_ frame: CGRect?) {
        interceptFrame = frame
    }

    func updateVisibility(_ visible: Bool) {
        isDockVisible = visible
    }

    /// Updates the Dock PID used for accessibility queries.
    func updateDockPid(_ pid: pid_t?) {
        dockPid = pid
    }

    func start() {
        guard eventTap == nil else {
            Logger.debug("DockClickInterceptor: already running")
            return
        }

        pendingClick = nil

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(Constants.eventMask),
            callback: DockClickInterceptor.eventCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Logger.debug("DockClickInterceptor: failed to create event tap (missing permission?)")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.debug("DockClickInterceptor: started")
    }

    func stop() {
        pendingClick = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        runLoopSource = nil
        eventTap = nil
        Logger.debug("DockClickInterceptor: stopped")
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // Handle rare tap-disable events
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout,
           let tap = eventTap {
            pendingClick = nil
            CGEvent.tapEnable(tap: tap, enable: true)
            Logger.debug("DockClickInterceptor: re-enabled after timeout")
            return Unmanaged.passUnretained(event)
        }

        // Track drag movement to distinguish clicks from drags
        if type == .leftMouseDragged {
            if var pending = pendingClick {
                if pending.dragState == .intercepted {
                    delegate?.dockClickInterceptorDidUpdateDrag(self, cursorPoint: event.location)
                    return nil
                }

                if pending.dragState == .unhandled {
                    return nil
                }

                let location = event.location
                let dx = abs(location.x - pending.downLocation.x)
                let dy = abs(location.y - pending.downLocation.y)
                if dx > Constants.dragThreshold || dy > Constants.dragThreshold {
                    // Call the appropriate delegate method based on whether the app is running
                    let accepted: Bool
                    if pending.isRunning {
                        accepted = delegate?.dockClickInterceptor(self, didBeginDragOnApp: pending.appURL, itemFrame: pending.itemFrame, cursorPoint: location) ?? false
                    } else {
                        accepted = delegate?.dockClickInterceptor(self, didBeginDragOnNonRunningApp: pending.appURL, itemFrame: pending.itemFrame, cursorPoint: location) ?? false
                    }

                    if accepted {
                        pending.dragState = .intercepted
                        pendingClick = pending
                        delegate?.dockClickInterceptorDidUpdateDrag(self, cursorPoint: location)
                        return nil
                    }

                    // Can't handle this drag - still swallow it so the Dock doesn't start rearranging.
                    pending.dragState = .unhandled
                    pendingClick = pending
                    return nil
                }

                // Swallow small drags so the Dock doesn't start rearranging before we decide it's a drag.
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // On mouse-up, intercept if we have a pending click that wasn't a drag
        if type == .leftMouseUp {
            guard let pending = pendingClick else {
                return Unmanaged.passUnretained(event)
            }
            pendingClick = nil

            switch pending.dragState {
            case .intercepted:
                // Complete the Dock's click tracking, then end the intercepted drag.
                postMouseUp(at: pending.downLocation)
                delegate?.dockClickInterceptorDidEndDrag(self, cursorPoint: event.location)
                return nil
            case .unhandled:
                // Still complete the Dock's click tracking, but don't trigger any Zonogy action.
                postMouseUp(at: pending.downLocation)
                return nil
            case .none:
                break
            }

            // Fully swallow the click - don't post any events to the Dock.
            // See SPECIFICATION-IMPLEMENTATION.md "Dock click interception activation workaround".
            delegate?.dockClickInterceptor(self, didInterceptClickOnApp: pending.appURL, itemFrame: pending.itemFrame, dockItemElement: pending.dockItemElement)
            return nil
        }

        guard type == .leftMouseDown else {
            return Unmanaged.passUnretained(event)
        }

        // Fast exit: Dock is hidden (autohide)
        guard isDockVisible else {
            return Unmanaged.passUnretained(event)
        }

        // Fast exit: no frame to intercept
        guard let frame = interceptFrame else {
            return Unmanaged.passUnretained(event)
        }

        // Fast exit: click outside the frame (most common case)
        let location = event.location
        guard frame.contains(location) else {
            return Unmanaged.passUnretained(event)
        }

        // Shift bypasses interception (spec: allow normal Dock behavior)
        // Control bypasses interception (spec: preserve Dock context menus)
        let flags = event.flags
        if flags.contains(.maskShift) || flags.contains(.maskControl) {
            return Unmanaged.passUnretained(event)
        }

        // Only intercept if the topmost element at this location is a Dock app item.
        // This prevents overlapping UI like menus from being hijacked by DockMenus.
        let topmostHit = findTopmostClickedAppDockItem(at: location)
        let result: ClickedAppResult
        switch topmostHit {
        case .dockApp(let clickedResult):
            result = clickedResult
        case .nonDock:
            // Preserve Dock hidden-state bookkeeping when we click inside a stale Dock frame.
            _ = findClickedAppDockItem(at: location)
            return Unmanaged.passUnretained(event)
        case .unavailable:
            guard let clickedResult = findClickedAppDockItem(at: location) else {
                return Unmanaged.passUnretained(event)
            }
            result = clickedResult
        }

        // Record the pending click - we'll intercept on mouse-up if it's not a drag
        pendingClick = PendingClick(
            downLocation: location,
            appURL: result.url,
            itemFrame: result.frame,
            isRunning: result.isRunning,
            dockItemElement: result.element
        )

        // Consume mouse-down so the Dock doesn't start a press-and-hold menu or icon drag.
        return nil
    }

    /// Result of finding a clicked app in the Dock.
    private struct ClickedAppResult {
        let url: URL
        let frame: CGRect
        let isRunning: Bool
        let element: AXUIElement
    }

    /// Uses the system-wide accessibility hit-test so we only intercept when the Dock app item
    /// is truly the topmost UI element at the click point.
    private func findTopmostClickedAppDockItem(at location: CGPoint) -> TopmostDockHit {
        guard let dockPid = dockProcessId() else {
            return .unavailable
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var elementAtPosition: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(location.x),
            Float(location.y),
            &elementAtPosition
        )

        guard status == .success, let element = elementAtPosition else {
            return .unavailable
        }

        if let result = clickedAppDockItemResultInParentChain(startingAt: element, dockPid: dockPid) {
            return .dockApp(result)
        }

        return .nonDock
    }

    /// Queries the Dock's accessibility tree to find what's at the click position.
    /// Returns the app URL, frame, and running status if it's an AXApplicationDockItem.
    private func findClickedAppDockItem(at location: CGPoint) -> ClickedAppResult? {
        guard let pid = dockProcessId() else {
            return nil
        }

        let dockApp = AXUIElementCreateApplication(pid)

        var elementAtPosition: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(dockApp, Float(location.x), Float(location.y), &elementAtPosition)

        guard result == .success, let element = elementAtPosition else {
            // AX query failed - Dock is hidden (autohide) or stale PID.
            if result != .success {
                dockPid = nil
            }
            // Notify that no Dock element was found at this position
            onDockNotFound?()
            return nil
        }

        guard isApplicationDockItem(element, ownedBy: pid) else {
            return nil
        }

        return clickedAppResult(fromDockItemElement: element)
    }

    private func dockProcessId() -> pid_t? {
        if let cached = dockPid {
            return cached
        }

        guard let found = ApplicationIdentity.runningApplication(bundleIdentifier: Constants.dockBundleIdentifier)?.processIdentifier else {
            return nil
        }

        dockPid = found
        return found
    }

    private func clickedAppDockItemResultInParentChain(startingAt element: AXUIElement, dockPid: pid_t) -> ClickedAppResult? {
        var currentElement: AXUIElement? = element
        var visitedHashes: Set<CFHashCode> = []
        let maxDepth = 16

        for _ in 0..<maxDepth {
            guard let current = currentElement else {
                return nil
            }

            let hash = CFHash(current)
            guard !visitedHashes.contains(hash) else {
                return nil
            }
            visitedHashes.insert(hash)

            if isApplicationDockItem(current, ownedBy: dockPid) {
                return clickedAppResult(fromDockItemElement: current)
            }

            currentElement = axParent(of: current)
        }

        return nil
    }

    private func isApplicationDockItem(_ element: AXUIElement, ownedBy pid: pid_t) -> Bool {
        var elementPid: pid_t = 0
        guard AXUIElementGetPid(element, &elementPid) == .success,
              elementPid == pid else {
            return false
        }

        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              let subrole = subroleRef as? String else {
            return false
        }

        return subrole == "AXApplicationDockItem"
    }

    private func clickedAppResult(fromDockItemElement element: AXUIElement) -> ClickedAppResult? {
        var urlRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef) == .success,
              let url = urlRef as? URL else {
            return nil
        }

        // Get the frame
        guard let frame = axFrame(of: element) else {
            return nil
        }

        // Check if the app is running
        let isRunning = ApplicationIdentity
            .bundleIdentifier(forApplicationURL: url)
            .map { ApplicationIdentity.isRunning(bundleIdentifier: $0) } ?? false

        return ClickedAppResult(url: url, frame: frame, isRunning: isRunning, element: element)
    }

    private func axParent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(cfValue, to: AXUIElement.self)
    }

    /// Extracts the AXFrame (position + size) from an accessibility element.
    private func axFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    /// Posts a synthetic mouse-up at the given location to complete the Dock's click tracking.
    private func postMouseUp(at location: CGPoint) {
        guard let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else {
            return
        }

        mouseUp.post(tap: .cghidEventTap)
    }

    private static let eventCallback: CGEventTapCallBack = { proxy, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let interceptor = Unmanaged<DockClickInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        return interceptor.processEvent(cgEvent, type: type)
    }
}
