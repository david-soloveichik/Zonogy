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

/// Intercepts global left-clicks within the Dock's revealed frame.
///
/// Intercepts clicks on application Dock items (AXApplicationDockItem), both running and non-running.
/// Clicks on folders, files, Launchpad, Trash pass through.
/// Drags are detected; eligible app-item drags are intercepted and routed into Zonogy.
///
/// Performance-critical: separate event taps keep the system-wide cost down. The press tap sees left
/// mouse-downs only while the Dock is showing, and answers on the mouse tap thread: a click outside
/// the Dock frame passes at once, without involving the main thread, and only a click inside it waits
/// for the main thread to decide (an Accessibility hit-test on the Dock, then the delegate). The
/// drag and release taps run only between an intercepted press and its release, so ordinary drags
/// anywhere else never wake Zonogy. Both stay on the main run loop, where the gesture state lives.
final class DockClickInterceptor {
    private enum Constants {
        static let dockBundleIdentifier = "com.apple.dock"
        /// Movement threshold in pixels to initiate a Dock drag interception.
        static let dragThreshold: CGFloat = 8.0
    }

    weak var delegate: DockClickInterceptorDelegate?

    /// Called when a click occurs in the Dock frame but no Dock element is found (Dock is hidden).
    var onDockNotFound: (() -> Void)?

    /// Returns true when the point lands on Zonogy UI drawn above the Dock (the add-zone and
    /// floating-zone pills). Such clicks always pass through, even when the topmost-element
    /// accessibility check is transiently unavailable.
    var isPointCoveredByZonogyEdgeUI: ((CGPoint) -> Bool)?

    /// The frame to intercept clicks within (Accessibility coordinates: origin at top-left of primary
    /// screen). Mirrored for the press tap's thread, which reads it on every left mouse-down.
    @ThreadSafe private var interceptFrame: CGRect? = nil

    /// Whether the Dock is currently considered visible. Mirrored likewise.
    @ThreadSafe private var isDockVisible = false

    /// Cached Dock PID for accessibility queries.
    private var dockPid: pid_t?

    /// Sees left mouse-downs; enabled only while the Dock is showing and located.
    private var pressTap: EventTapController?

    /// Sees drags; enabled only while a click is pending.
    private var dragTap: EventTapController?

    /// Sees the release; enabled only while a click is pending.
    private var releaseTap: EventTapController?

    /// Tracks a pending click that may be intercepted on mouse-up.
    private var pendingClick: PendingClick? {
        didSet {
            dragTap?.isEnabled = pendingClick != nil
            releaseTap?.isEnabled = pendingClick != nil
        }
    }

    private enum DragState {
        case none
        case intercepted
        /// A declined or cancelled drag: the rest of the gesture is swallowed without any action.
        case ignored
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
        syncPressTapEnabled()
    }

    /// Cancel the in-flight intercepted drag (e.g., user pressed Esc). Further drag updates are
    /// ignored and the eventual mouse-up is consumed without resolving a drop.
    func cancelInProgressDrag() {
        guard var pending = pendingClick, pending.dragState == .intercepted else {
            return
        }
        pending.dragState = .ignored
        pendingClick = pending
        Logger.debug("DockClickInterceptor: in-progress drag marked cancelled (Escape)")
    }

    func updateVisibility(_ visible: Bool) {
        isDockVisible = visible
        syncPressTapEnabled()
    }

    /// Updates the Dock PID used for accessibility queries.
    func updateDockPid(_ pid: pid_t?) {
        dockPid = pid
    }

    func start() {
        guard pressTap == nil else {
            Logger.debug("DockClickInterceptor: already running")
            return
        }

        pendingClick = nil

        let press = makeTap(
            name: "DockClickInterceptor press", events: [.leftMouseDown],
            tapLocation: .cghidEventTap, runLoop: EventTapThread.mouse.runLoop
        ) { [weak self] _, event in
            self?.processPress(event) ?? .pass
        }
        // Let WindowServer update the cursor before swallowing movement, including during capture.
        let drag = makeTap(
            name: "DockClickInterceptor drag", events: [.leftMouseDragged],
            tapLocation: .cgAnnotatedSessionEventTap, runLoop: CFRunLoopGetMain()
        ) { [weak self] _, event in
            self?.processDrag(event) ?? .pass
        }
        // The press was swallowed at HID, so its release may never reach the annotated tap.
        // Intercept the release at HID too, for both clicks and drags (including cancellation).
        let release = makeTap(
            name: "DockClickInterceptor release", events: [.leftMouseUp],
            tapLocation: .cghidEventTap, runLoop: CFRunLoopGetMain()
        ) { [weak self] _, event in
            self?.processRelease(event) ?? .pass
        }
        drag.isEnabled = false
        release.isEnabled = false
        guard press.start(), drag.start(), release.start() else {
            press.stop()
            drag.stop()
            release.stop()
            return
        }
        pressTap = press
        dragTap = drag
        releaseTap = release
        syncPressTapEnabled()
    }

    func stop() {
        pendingClick = nil
        pressTap?.stop()
        pressTap = nil
        dragTap?.stop()
        dragTap = nil
        releaseTap?.stop()
        releaseTap = nil
        Logger.debug("DockClickInterceptor: stopped")
    }

    private func makeTap(
        name: String,
        events: [CGEventType],
        tapLocation: CGEventTapLocation,
        runLoop: CFRunLoop,
        handler: @escaping EventTapController.Handler
    ) -> EventTapController {
        EventTapController(
            name: name,
            events: events,
            tapLocation: tapLocation,
            runLoop: runLoop,
            onDisabled: { [weak self] type in
                // A user-input report is indistinguishable from the (possibly late) echo of switching
                // a tap off, so only a timeout is taken to mean the pending click cannot be trusted.
                // The pending click is main-thread state: the drag and release taps report on main and
                // clear it at once (a clearing queued behind a newer press would erase that press),
                // while the press tap reports on the mouse thread and hands the clearing to main.
                guard type == .tapDisabledByTimeout else { return }
                if Thread.isMainThread {
                    self?.pendingClick = nil
                } else {
                    MainRunLoop.perform { self?.pendingClick = nil }
                }
            },
            handler: handler
        )
    }

    /// Clicks while the Dock is hidden or not yet located can never be intercepted, so the press
    /// tap is switched off in those states rather than passing every click through Zonogy.
    private func syncPressTapEnabled() {
        pressTap?.isEnabled = isDockVisible && interceptFrame != nil
    }

    /// The drag tap's callback, on the main run loop: tells a drag from a click and follows an
    /// intercepted drag. Every drag of a pending click is swallowed so the Dock never starts
    /// rearranging its icons.
    private func processDrag(_ event: CGEvent) -> EventTapDecision {
        guard var pending = pendingClick else {
            return .pass
        }
        let location = event.location
        switch pending.dragState {
        case .intercepted:
            delegate?.dockClickInterceptorDidUpdateDrag(self, cursorPoint: location)
            return .swallow
        case .ignored:
            return .swallow
        case .none:
            break
        }

        // Within the threshold, the press is still a click.
        let dx = abs(location.x - pending.downLocation.x)
        let dy = abs(location.y - pending.downLocation.y)
        guard dx > Constants.dragThreshold || dy > Constants.dragThreshold else {
            return .swallow
        }

        // Call the appropriate delegate method based on whether the app is running
        let accepted: Bool
        if pending.isRunning {
            accepted = delegate?.dockClickInterceptor(self, didBeginDragOnApp: pending.appURL, itemFrame: pending.itemFrame, cursorPoint: location) ?? false
        } else {
            accepted = delegate?.dockClickInterceptor(self, didBeginDragOnNonRunningApp: pending.appURL, itemFrame: pending.itemFrame, cursorPoint: location) ?? false
        }
        pending.dragState = accepted ? .intercepted : .ignored
        pendingClick = pending
        if accepted {
            delegate?.dockClickInterceptorDidUpdateDrag(self, cursorPoint: location)
        }
        return .swallow
    }

    /// The release tap's callback, on the main run loop: finishes the pending click or drag at the
    /// physical release location.
    private func processRelease(_ event: CGEvent) -> EventTapDecision {
        guard let pending = pendingClick else {
            return .pass
        }
        pendingClick = nil

        // The Dock never received the press, so there is no native click tracking to finish.
        // Posting a synthetic mouse-up at the press location would move the cursor back there.
        switch pending.dragState {
        case .intercepted:
            delegate?.dockClickInterceptorDidEndDrag(self, cursorPoint: event.location)
        case .none:
            delegate?.dockClickInterceptor(self, didInterceptClickOnApp: pending.appURL, itemFrame: pending.itemFrame, dockItemElement: pending.dockItemElement)
        case .ignored:
            break
        }
        return .swallow
    }

    /// The press tap's callback, on the mouse tap thread. The fast exits need only the mirrored Dock
    /// state; a click inside the Dock frame is decided on the main thread while the system waits.
    private func processPress(_ event: CGEvent) -> EventTapDecision {
        // Fast exit: Dock is hidden (autohide), or its frame is not known
        guard isDockVisible, let frame = interceptFrame else {
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

        return MainRunLoop.performAndWait {
            self.interceptPress(inDockFrameAt: location)
        }
    }

    /// Decides a press inside the Dock frame: whether a Dock app item is the topmost UI at the point,
    /// and if so records the pending click and consumes the press.
    private func interceptPress(inDockFrameAt location: CGPoint) -> EventTapDecision {
        // The interceptor may have been stopped while this decision waited its turn.
        guard pressTap != nil else {
            return .pass
        }

        // Zonogy's own edge pills render above the Dock; clicks on them belong to the pills.
        if isPointCoveredByZonogyEdgeUI?(location) == true {
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
}
