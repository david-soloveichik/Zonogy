import Foundation
import ApplicationServices

/// Notified when a left-click is intercepted within the Dock frame.
protocol DockClickInterceptorDelegate: AnyObject {
    func dockClickInterceptor(_ interceptor: DockClickInterceptor, didInterceptClickAt location: CGPoint)
}

/// Intercepts global left-clicks within the Dock's AXList frame.
/// Performance-critical: exits as fast as possible when the click is outside the frame.
final class DockClickInterceptor {
    private enum Constants {
        static let eventMask = (1 << CGEventType.leftMouseDown.rawValue)
    }

    weak var delegate: DockClickInterceptorDelegate?

    /// The frame to intercept clicks within (Accessibility coordinates: origin at top-left of primary screen).
    private var interceptFrame: CGRect?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func updateFrame(_ frame: CGRect?) {
        interceptFrame = frame
    }

    func start() {
        guard eventTap == nil else {
            Logger.debug("DockClickInterceptor: already running")
            return
        }

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
        // We only registered for leftMouseDown, so that's the expected case
        if type != .leftMouseDown {
            // Handle rare tap-disable events
            if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout,
               let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.debug("DockClickInterceptor: re-enabled after timeout")
            }
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

        // Shift modifier bypasses interception
        if event.flags.contains(.maskShift) {
            return Unmanaged.passUnretained(event)
        }

        // Click is within the Dock frame - intercept it
        delegate?.dockClickInterceptor(self, didInterceptClickAt: location)
        return nil
    }

    private static let eventCallback: CGEventTapCallBack = { proxy, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let interceptor = Unmanaged<DockClickInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        return interceptor.processEvent(cgEvent, type: type)
    }
}
