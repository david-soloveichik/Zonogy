import Foundation
import ApplicationServices

/// Intercepts global Control+Command left-clicks so zones can be retargeted without
/// delivering the click to the underlying application.
protocol ZoneClickInterceptorDelegate: AnyObject {
    /// - Returns: true if the gesture was handled and the click should be swallowed.
    func zoneClickInterceptor(_ interceptor: ZoneClickInterceptor, shouldConsumeClickAt location: CGPoint) -> Bool
}

final class ZoneClickInterceptor {
    private enum Constants {
        static let requiredModifiers: CGEventFlags = [.maskCommand, .maskControl]
        static let eventMask = (1 << CGEventType.leftMouseDown.rawValue)
    }

    weak var delegate: ZoneClickInterceptorDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start(delegate: ZoneClickInterceptorDelegate) {
        self.delegate = delegate

        guard eventTap == nil else {
            Logger.debug("Zone click interceptor already running")
            return
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(Constants.eventMask),
            callback: ZoneClickInterceptor.eventCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Logger.debug("Failed to install Control+Command click interceptor (missing permission?)")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.debug("Zone click interceptor started")
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
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByUserInput, .tapDisabledByTimeout:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.debug("Re-enabled Control+Command click interceptor after timeout")
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        guard let delegate,
              event.flags.contains(Constants.requiredModifiers) else {
            return Unmanaged.passUnretained(event)
        }

        let location = event.location
        if delegate.zoneClickInterceptor(self, shouldConsumeClickAt: location) {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private static let eventCallback: CGEventTapCallBack = { proxy, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let interceptor = Unmanaged<ZoneClickInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        return interceptor.processEvent(cgEvent, type: type)
    }
}
