import Foundation
import ApplicationServices
import AppKit

/// Notified when a left-click is intercepted on a running app in the Dock.
protocol DockClickInterceptorDelegate: AnyObject {
    /// Called when a click on a running app's Dock icon was intercepted.
    /// - Parameters:
    ///   - interceptor: The interceptor instance.
    ///   - appURL: The URL of the clicked application bundle.
    ///   - itemFrame: The accessibility frame of the clicked Dock item (origin at top-left of primary screen).
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didInterceptClickOnApp appURL: URL, itemFrame: CGRect)
}

/// Intercepts global left-clicks within the Dock's AXList frame.
/// Performance-critical: exits as fast as possible when the click is outside the frame.
///
/// Only intercepts clicks on running application Dock items (AXApplicationDockItem).
/// Clicks on folders, files, Launchpad, Trash, or non-running apps pass through.
final class DockClickInterceptor {
    private enum Constants {
        static let eventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        static let dockBundleIdentifier = "com.apple.dock"
        /// Ensures we fully consume a Dock click (down + up) so no trailing events leak to the
        /// previously-active app after we activate a new one via the click-intercept path.
        static let clickConsumeTimeout: TimeInterval = 15.0
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
    private var consumeLeftMouseUntil: Date?

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

        consumeLeftMouseUntil = nil

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
        consumeLeftMouseUntil = nil
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
            consumeLeftMouseUntil = nil
            CGEvent.tapEnable(tap: tap, enable: true)
            Logger.debug("DockClickInterceptor: re-enabled after timeout")
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseUp {
            if shouldConsumeFollowupLeftMouseEvent(type: type) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // We only intercept Dock clicks on leftMouseDown; follow-up leftMouseUp is consumed via state.
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

        // Query Dock accessibility to find the clicked element
        // Only intercept if it's a running app's Dock icon
        guard let result = findClickedRunningApp(at: location) else {
            // Not a running app - let click through
            return Unmanaged.passUnretained(event)
        }

        consumeLeftMouseUntil = Date().addingTimeInterval(Constants.clickConsumeTimeout)

        // Click is on a running app's Dock icon - intercept it
        delegate?.dockClickInterceptor(self, didInterceptClickOnApp: result.url, itemFrame: result.frame)
        return nil
    }

    private func shouldConsumeFollowupLeftMouseEvent(type: CGEventType) -> Bool {
        guard let deadline = consumeLeftMouseUntil else {
            return false
        }
        if Date() > deadline {
            consumeLeftMouseUntil = nil
            return false
        }
        if type == .leftMouseUp {
            consumeLeftMouseUntil = nil
        }
        return true
    }

    /// Result of finding a clicked running app in the Dock.
    private struct ClickedAppResult {
        let url: URL
        let frame: CGRect
    }

    /// Queries the Dock's accessibility tree to find what's at the click position.
    /// Returns the app URL and frame only if it's an AXApplicationDockItem for a running app.
    private func findClickedRunningApp(at location: CGPoint) -> ClickedAppResult? {
        // Use cached PID or look it up
        let pid: pid_t
        if let cached = dockPid {
            pid = cached
        } else if let found = NSRunningApplication.runningApplications(withBundleIdentifier: Constants.dockBundleIdentifier).first?.processIdentifier {
            dockPid = found
            pid = found
        } else {
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

        // Check if it's an AXApplicationDockItem (subrole)
        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              let subrole = subroleRef as? String,
              subrole == "AXApplicationDockItem" else {
            return nil
        }

        // Get the URL
        var urlRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef) == .success,
              let url = urlRef as? URL else {
            return nil
        }

        // Check if the app is running
        guard let bundleId = Bundle(url: url)?.bundleIdentifier,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first != nil else {
            return nil
        }

        // Get the frame
        guard let frame = axFrame(of: element) else {
            return nil
        }

        return ClickedAppResult(url: url, frame: frame)
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

    private static let eventCallback: CGEventTapCallBack = { proxy, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let interceptor = Unmanaged<DockClickInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        return interceptor.processEvent(cgEvent, type: type)
    }
}
