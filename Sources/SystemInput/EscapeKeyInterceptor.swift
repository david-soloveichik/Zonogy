/// CGEventTap that swallows the Escape key while running, so that an
/// in-flight cursor-driven drag can cancel without leaking the keystroke into
/// the frontmost app. Invokes its callback synchronously from inside the tap
/// callback (on the main thread, since the source is installed on the main
/// runloop) so the caller can close races against pending mouse events before
/// the swallowed Escape returns control to the runloop. Callers are
/// responsible for keeping the work small or deferring expensive teardown.

import ApplicationServices
import Carbon
import Foundation

final class EscapeKeyInterceptor {
    private let logPrefix: String
    private let onEscape: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(logPrefix: String, onEscape: @escaping () -> Void) {
        self.logPrefix = logPrefix
        self.onEscape = onEscape
    }

    func start() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: EscapeKeyInterceptor.eventCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Logger.debug("\(logPrefix): failed to install Escape event tap (missing Input Monitoring permission?)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.debug("\(logPrefix): Escape event tap started")
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
                Logger.debug("\(logPrefix): re-enabled Escape event tap after timeout")
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == CGKeyCode(kVK_Escape) else {
                return Unmanaged.passUnretained(event)
            }
            // Synchronous so the caller can invalidate any racing mouse-up state before this
            // CGEventTap callback returns. The caller is responsible for keeping its work
            // small or deferring expensive teardown via its own dispatch.
            onEscape()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let interceptor = Unmanaged<EscapeKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        return interceptor.processEvent(cgEvent, type: type)
    }

    deinit {
        stop()
    }
}
