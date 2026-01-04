/// CGEventTap-based interceptor for recording keyboard shortcuts in preferences
/// Captures system-level shortcuts (like Cmd-Tab) that NSEvent monitors cannot intercept

import ApplicationServices
import Carbon
import Foundation

protocol ShortcutRecordingInterceptorDelegate: AnyObject {
    /// Called when a key event is captured. The delegate should handle the shortcut.
    func shortcutRecordingInterceptor(
        _ interceptor: ShortcutRecordingInterceptor,
        didCapture keyCode: CGKeyCode,
        modifiers: CGEventFlags
    )

    /// Called when Escape is pressed with no modifiers, indicating cancel.
    func shortcutRecordingInterceptorDidCancel(_ interceptor: ShortcutRecordingInterceptor)
}

final class ShortcutRecordingInterceptor {
    private enum Constants {
        static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        static let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        static let escapeKeyCode = CGKeyCode(kVK_Escape)
    }

    weak var delegate: ShortcutRecordingInterceptorDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start(delegate: ShortcutRecordingInterceptorDelegate) {
        self.delegate = delegate

        guard eventTap == nil else {
            Logger.debug("ShortcutRecordingInterceptor already running")
            return
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(Constants.eventMask),
            callback: ShortcutRecordingInterceptor.eventCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Logger.debug("Failed to create ShortcutRecordingInterceptor (missing Input Monitoring permission?)")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.debug("ShortcutRecordingInterceptor started")
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
        delegate = nil
        Logger.debug("ShortcutRecordingInterceptor stopped")
    }

    var isRunning: Bool {
        eventTap != nil
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByUserInput, .tapDisabledByTimeout:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.debug("Re-enabled ShortcutRecordingInterceptor after timeout")
            }
            return Unmanaged.passUnretained(event)
        case .keyDown, .flagsChanged:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        // Ignore pure modifier key presses (flagsChanged without a key)
        if type == .flagsChanged {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let relevantFlags = event.flags.intersection(Constants.relevantModifierFlags)

        // Escape with no modifiers = cancel
        if keyCode == Constants.escapeKeyCode && relevantFlags.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.shortcutRecordingInterceptorDidCancel(self)
            }
            return nil // Swallow the event
        }

        // Notify delegate of the captured key
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.shortcutRecordingInterceptor(self, didCapture: keyCode, modifiers: relevantFlags)
        }

        // Swallow the event to prevent system handling (e.g., Cmd-Tab app switching)
        return nil
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let interceptor = Unmanaged<ShortcutRecordingInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        return interceptor.processEvent(cgEvent, type: type)
    }

    deinit {
        stop()
    }
}
