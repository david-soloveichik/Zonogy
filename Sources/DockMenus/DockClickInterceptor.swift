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

    /// Called when an intercepted drag ends without its release (see `PressGestureClaimant.abortDrag`);
    /// nothing is dropped.
    func dockClickInterceptorDidAbortDrag(_ interceptor: DockClickInterceptor)
}

/// Intercepts global left-clicks within the Dock's revealed frame.
///
/// Intercepts clicks on application Dock items (AXApplicationDockItem), both running and non-running.
/// Clicks on folders, files, Launchpad, Trash pass through.
/// Drags are detected; eligible app-item drags are intercepted and routed into Zonogy.
///
/// The gesture is taken over by a `PressGestureInterceptor`, whose press tap sees left mouse-downs
/// only while the Dock is showing: a click outside the Dock frame passes at once on the mouse tap
/// thread, and only a click inside it waits for the main thread to decide (an Accessibility hit-test
/// on the Dock, then the delegate).
final class DockClickInterceptor {
    private enum Constants {
        static let dockBundleIdentifier = "com.apple.dock"
    }

    weak var delegate: DockClickInterceptorDelegate?

    /// Called when a click occurs in the Dock frame but no Dock element is found (Dock is hidden).
    var onDockNotFound: (() -> Void)?

    /// Returns true when the point lands on Zonogy UI drawn above the Dock (the add-zone and
    /// floating-zone pills). Such clicks always pass through, even when the topmost-element
    /// accessibility check is transiently unavailable.
    var isPointCoveredByZonogyEdgeUI: ((CGPoint) -> Bool)?

    /// Called after the release ending an intercepted gesture is handled and swallowed: no event
    /// monitor sees that mouse-up, so whatever waits for it must be told.
    var onSwallowedRelease: (() -> Void)?

    /// The frame to intercept clicks within (Accessibility coordinates: origin at top-left of primary
    /// screen). Mirrored for the press tap's thread, which reads it on every left mouse-down.
    @ThreadSafe private var interceptFrame: CGRect? = nil

    /// Whether the Dock is currently considered visible. Mirrored likewise.
    @ThreadSafe private var isDockVisible = false

    /// Cached Dock PID for accessibility queries.
    private var dockPid: pid_t?

    private lazy var gesture = PressGestureInterceptor(name: "DockClickInterceptor", claimant: self)

    func updateFrame(_ frame: CGRect?) {
        interceptFrame = frame
        syncPressTapEnabled()
    }

    /// Cancel the in-flight intercepted drag (e.g., user pressed Esc). Further drag updates are
    /// ignored and the eventual mouse-up is consumed without resolving a drop.
    func cancelInProgressDrag() {
        gesture.cancelInProgressDrag()
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
        gesture.start()
    }

    func stop() {
        gesture.stop()
    }

    /// Clicks while the Dock is hidden or not yet located can never be intercepted, so the press
    /// tap is switched off in those states rather than passing every click through Zonogy.
    private func syncPressTapEnabled() {
        gesture.isPressTapEnabled = isDockVisible && interceptFrame != nil
    }

    /// A pressed app item in the Dock: the claim on a gesture taken over.
    struct ClickedApp {
        let url: URL
        let frame: CGRect
        let isRunning: Bool
        let element: AXUIElement
    }

    /// Queries the Dock's accessibility tree to find what's at the click position.
    /// Returns the app URL, frame, and running status if it's an AXApplicationDockItem.
    private func findClickedAppDockItem(at location: CGPoint) -> ClickedApp? {
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

    private func clickedAppResult(fromDockItemElement element: AXUIElement) -> ClickedApp? {
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

        return ClickedApp(url: url, frame: frame, isRunning: isRunning, element: element)
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

// MARK: - PressGestureClaimant

extension DockClickInterceptor: PressGestureClaimant {
    /// Runs on the mouse tap thread, so it reads only the mirrored Dock state.
    func mayClaimPress(_ event: CGEvent) -> Bool {
        // Fast exit: Dock is hidden (autohide), its frame is not known, or the click is outside it
        // (the most common case).
        guard isDockVisible, let frame = interceptFrame, frame.contains(event.location) else {
            return false
        }
        // Shift bypasses interception (spec: allow normal Dock behavior).
        // Control bypasses interception (spec: preserve Dock context menus).
        return event.flags.isDisjoint(with: [.maskShift, .maskControl])
    }

    /// Claims a press inside the Dock frame when a Dock app item is the topmost UI at the point. The
    /// press is consumed so the Dock can't start a press-and-hold menu or icon drag.
    func claimPress(_ event: CGEvent) -> ClickedApp? {
        let location = event.location

        // Zonogy's own edge pills render above the Dock; clicks on them belong to the pills.
        if isPointCoveredByZonogyEdgeUI?(location) == true {
            return nil
        }

        guard let dockPid = dockProcessId() else {
            return nil
        }
        // Only intercept if the topmost element at this location is a Dock app item.
        // This prevents overlapping UI like menus from being hijacked by DockMenus.
        let hit = AccessibilityHitTest.topmost(at: location) { element in
            isApplicationDockItem(element, ownedBy: dockPid) ? clickedAppResult(fromDockItemElement: element) : nil
        }
        switch hit {
        case .match(let clickedApp):
            return clickedApp
        case .noMatch:
            // Preserve Dock hidden-state bookkeeping when we click inside a stale Dock frame.
            updateDockHiddenStateBookkeeping(at: location)
            return nil
        case .unavailable:
            return findClickedAppDockItem(at: location)
        }
    }

    func beginDrag(of app: ClickedApp, at point: CGPoint) -> Bool {
        if app.isRunning {
            return delegate?.dockClickInterceptor(self, didBeginDragOnApp: app.url, itemFrame: app.frame, cursorPoint: point) ?? false
        }
        return delegate?.dockClickInterceptor(self, didBeginDragOnNonRunningApp: app.url, itemFrame: app.frame, cursorPoint: point) ?? false
    }

    func updateDrag(to point: CGPoint) {
        delegate?.dockClickInterceptorDidUpdateDrag(self, cursorPoint: point)
    }

    func endDrag(at point: CGPoint) {
        delegate?.dockClickInterceptorDidEndDrag(self, cursorPoint: point)
    }

    func abortDrag() {
        delegate?.dockClickInterceptorDidAbortDrag(self)
    }

    /// The Dock never received the press, so the click is Zonogy's to act on.
    func click(_ app: ClickedApp, release: CGEvent) {
        delegate?.dockClickInterceptor(self, didInterceptClickOnApp: app.url, itemFrame: app.frame, dockItemElement: app.element)
    }

    func didSwallowRelease() {
        onSwallowedRelease?()
    }
}
