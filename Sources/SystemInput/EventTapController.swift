/// Owns the common lifecycle for a swallowing CGEventTap, including switching it off while its
/// owner has no use for it: a disabled tap costs nothing per event, whereas an enabled active tap
/// makes the system wait on this process for every matching event. The tap is serviced by the run
/// loop it is given: the main run loop by default, or `EventTapThread.runLoop` for a tap whose
/// callback must answer while the main thread is busy.

import ApplicationServices
import Foundation

enum EventTapDecision {
    case pass
    case swallow
}

final class EventTapController {
    /// Runs synchronously inside the CGEventTap callback, on the thread of the tap's run loop.
    /// Keep work small; defer expensive follow-up with `DispatchQueue.main.async`.
    typealias Handler = (CGEventType, CGEvent) -> EventTapDecision

    private let name: String
    private let eventsOfInterest: CGEventMask
    private let tapLocation: CGEventTapLocation
    private let tapPlacement: CGEventTapPlacement
    private let tapOptions: CGEventTapOptions
    private let runLoop: CFRunLoop
    /// Called with the report type when the system reports the tap disabled, before the tap is
    /// re-enabled. A timeout means events flowed past the tap while this process stalled. A
    /// user-input report also follows this controller's own switch-off (possibly late, after the
    /// tap is wanted again), so owners that toggle `isEnabled` should ignore that type.
    private let onDisabled: ((CGEventType) -> Void)?
    private let handler: Handler

    /// The tap and the state its owner wants. Owners start, stop, and toggle from the main thread
    /// while the callback may be running on the tap's thread, so both sides go through this lock.
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wantsEnabled = true

    init(
        name: String,
        events: [CGEventType],
        tapLocation: CGEventTapLocation = .cghidEventTap,
        tapPlacement: CGEventTapPlacement = .headInsertEventTap,
        tapOptions: CGEventTapOptions = .defaultTap,
        runLoop: CFRunLoop = CFRunLoopGetMain(),
        onDisabled: ((CGEventType) -> Void)? = nil,
        handler: @escaping Handler
    ) {
        self.name = name
        self.eventsOfInterest = Self.mask(for: events)
        self.tapLocation = tapLocation
        self.tapPlacement = tapPlacement
        self.tapOptions = tapOptions
        self.runLoop = runLoop
        self.onDisabled = onDisabled
        self.handler = handler
    }

    var isRunning: Bool {
        lock.withLock { eventTap != nil }
    }

    /// Whether the tap receives events. May be set before or after `start()`. Switching the tap off
    /// takes effect before the next event; the system also echoes the switch-off as a
    /// `tapDisabledByUserInput` report (see `onDisabled`).
    var isEnabled: Bool {
        get { lock.withLock { wantsEnabled } }
        set {
            let tap: CFMachPort? = lock.withLock {
                guard wantsEnabled != newValue else { return nil }
                wantsEnabled = newValue
                return eventTap
            }
            guard let tap else { return }
            CGEvent.tapEnable(tap: tap, enable: newValue)
            Logger.debug("\(name) event tap \(newValue ? "enabled" : "disabled")")
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else {
            Logger.debug("\(name) already running")
            return true
        }

        guard let tap = CGEvent.tapCreate(
            tap: tapLocation,
            place: tapPlacement,
            options: tapOptions,
            eventsOfInterest: eventsOfInterest,
            callback: EventTapController.eventCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Logger.error("Failed to install \(name) event tap (missing Input Monitoring permission?)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let enabled: Bool = lock.withLock {
            eventTap = tap
            runLoopSource = source
            return wantsEnabled
        }
        if let source {
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CFRunLoopWakeUp(runLoop)
        }
        CGEvent.tapEnable(tap: tap, enable: enabled)
        Logger.debug("\(name) event tap started (enabled: \(enabled))")
        return true
    }

    func stop() {
        var tap: CFMachPort?
        var source: CFRunLoopSource?
        lock.withLock {
            tap = eventTap
            source = runLoopSource
            eventTap = nil
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            // Let the owner settle its gesture state before the tap resumes receiving events. The
            // owner may switch the tap off in response, in which case it stays off.
            onDisabled?(type)
            if type == .tapDisabledByTimeout {
                Logger.keep("\(name) event tap timed out; \(isEnabled ? "re-enabling it" : "leaving it off")")
            }
            let tap: CFMachPort? = lock.withLock { wantsEnabled ? eventTap : nil }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch handler(type, event) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        }
    }

    private static func mask(for eventTypes: [CGEventType]) -> CGEventMask {
        eventTypes.reduce(CGEventMask(0)) { mask, eventType in
            mask | (CGEventMask(1) << eventType.rawValue)
        }
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let controller = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.processEvent(cgEvent, type: type)
    }

    deinit {
        stop()
    }
}
