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

    private var eventTap: EventTapController?

    /// Tracks a pending click that may be intercepted on mouse-up.
    private var pendingClick: PendingClick?

    private enum DragState {
        case none
        case intercepted
        case unhandled
        case cancelled
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

    /// Mark the in-flight intercepted drag as cancelled (e.g., user pressed Esc). Further
    /// drag updates are ignored and the eventual mouse-up will not post a synthetic mouse-up
    /// or fire the drag-end delegate — it is consumed silently so the Dock takes no action.
    func cancelInProgressDrag() {
        guard var pending = pendingClick, pending.dragState == .intercepted else {
            return
        }
        pending.dragState = .cancelled
        pendingClick = pending
        Logger.debug("DockClickInterceptor: in-progress drag marked cancelled (Escape)")
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

        let tap = EventTapController(
            name: "DockClickInterceptor",
            events: [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
            onDisabled: { [weak self] _ in
                self?.pendingClick = nil
            },
            handler: { [weak self] type, event in
                self?.processEvent(event, type: type) ?? .pass
            }
        )
        if tap.start() {
            eventTap = tap
        }
    }

    func stop() {
        pendingClick = nil
        eventTap?.stop()
        eventTap = nil
        Logger.debug("DockClickInterceptor: stopped")
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> EventTapDecision {
        // Track drag movement to distinguish clicks from drags
        if type == .leftMouseDragged {
            if var pending = pendingClick {
                if pending.dragState == .intercepted {
                    delegate?.dockClickInterceptorDidUpdateDrag(self, cursorPoint: event.location)
                    return .swallow
                }

                if pending.dragState == .unhandled || pending.dragState == .cancelled {
                    return .swallow
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
                        return .swallow
                    }

                    // Can't handle this drag - still swallow it so the Dock doesn't start rearranging.
                    pending.dragState = .unhandled
                    pendingClick = pending
                    return .swallow
                }

                // Swallow small drags so the Dock doesn't start rearranging before we decide it's a drag.
                return .swallow
            }
            return .pass
        }

        // On mouse-up, intercept if we have a pending click that wasn't a drag
        if type == .leftMouseUp {
            guard let pending = pendingClick else {
                return .pass
            }
            pendingClick = nil

            switch pending.dragState {
            case .intercepted:
                // Complete the Dock's click tracking, then end the intercepted drag.
                postMouseUp(at: pending.downLocation)
                delegate?.dockClickInterceptorDidEndDrag(self, cursorPoint: event.location)
                return .swallow
            case .unhandled:
                // Still complete the Dock's click tracking, but don't trigger any Zonogy action.
                postMouseUp(at: pending.downLocation)
                return .swallow
            case .cancelled:
                // User cancelled mid-drag (Escape). Drop the eventual mouse-up silently — no
                // synthetic mouse-up to the Dock and no drag-end delegate.
                return .swallow
            case .none:
                break
            }

            // Fully swallow the click - don't post any events to the Dock.
            // See SPECIFICATION-IMPLEMENTATION.md "Dock click interception activation workaround".
            delegate?.dockClickInterceptor(self, didInterceptClickOnApp: pending.appURL, itemFrame: pending.itemFrame, dockItemElement: pending.dockItemElement)
            return .swallow
        }

        guard type == .leftMouseDown else {
            return .pass
        }

        // Fast exit: Dock is hidden (autohide)
        guard isDockVisible else {
            return .pass
        }

        // Fast exit: no frame to intercept
        guard let frame = interceptFrame else {
            return .pass
        }

        // Fast exit: click outside the frame (most common case)
        let location = event.location
        guard frame.contains(location) else {
            return .pass
        }

        // Shift bypasses interception (spec: allow normal Dock behavior)
        // Control bypasses interception (spec: preserve Dock context menus)
        let flags = event.flags
        if flags.contains(.maskShift) || flags.contains(.maskControl) {
            return .pass
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
            updateDockHiddenStateBookkeeping(at: location)
            return .pass
        case .unavailable:
            guard let clickedResult = findClickedAppDockItem(at: location) else {
                return .pass
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
        return .swallow
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
        let status = AXCall.copyElementAtPosition(
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
        guard let pid = dockProcessId(),
              let element = dockElement(at: location, dockPid: pid) else {
            return nil
        }

        guard isApplicationDockItem(element, ownedBy: pid) else {
            return nil
        }

        return clickedAppResult(fromDockItemElement: element)
    }

    /// Performs the Dock-local hit test used for visibility bookkeeping.
    /// If the Dock no longer resolves an element at this point, treat the cached Dock PID as stale.
    private func updateDockHiddenStateBookkeeping(at location: CGPoint) {
        guard let pid = dockProcessId() else {
            return
        }
        _ = dockElement(at: location, dockPid: pid)
    }

    private func dockElement(at location: CGPoint, dockPid: pid_t) -> AXUIElement? {
        let dockApp = AXUIElementCreateApplication(dockPid)

        var elementAtPosition: AXUIElement?
        let result = AXCall.copyElementAtPosition(dockApp, Float(location.x), Float(location.y), &elementAtPosition)

        guard result == .success, let element = elementAtPosition else {
            // AX query failed - Dock is hidden (autohide) or stale PID.
            if result != .success {
                self.dockPid = nil
            }
            // Notify that no Dock element was found at this position
            onDockNotFound?()
            return nil
        }

        return element
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
        guard AXCall.copyAttribute(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              let subrole = subroleRef as? String else {
            return false
        }

        return subrole == "AXApplicationDockItem"
    }

    private func clickedAppResult(fromDockItemElement element: AXUIElement) -> ClickedAppResult? {
        var urlRef: CFTypeRef?
        guard AXCall.copyAttribute(element, kAXURLAttribute as CFString, &urlRef) == .success,
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
        guard AXCall.copyAttribute(element, kAXParentAttribute as CFString, &value) == .success,
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

        guard AXCall.copyAttribute(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXCall.copyAttribute(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
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
}
