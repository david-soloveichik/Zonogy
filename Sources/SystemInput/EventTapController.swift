/// Owns the common lifecycle for a swallowing CGEventTap, including switching it off while its
/// owner has no use for it: a disabled tap costs nothing per event, whereas an enabled active tap
/// makes the system wait on this process for every matching event.

import ApplicationServices
import Foundation

enum EventTapDecision {
    case pass
    case swallow
}

final class EventTapController {
    /// Runs synchronously on the main run loop inside the CGEventTap callback.
    /// Keep work small; defer expensive follow-up with `DispatchQueue.main.async`.
    typealias Handler = (CGEventType, CGEvent) -> EventTapDecision

    private let name: String
    private let eventsOfInterest: CGEventMask
    private let tapLocation: CGEventTapLocation
    private let tapPlacement: CGEventTapPlacement
    private let tapOptions: CGEventTapOptions
    /// Called with the report type when the system reports the tap disabled, before the tap is
    /// re-enabled. A timeout means events flowed past the tap while this process stalled. A
    /// user-input report also follows this controller's own switch-off (possibly late, after the
    /// tap is wanted again), so owners that toggle `isEnabled` should ignore that type.
    private let onDisabled: ((CGEventType) -> Void)?
    private let handler: Handler

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether the tap receives events. May be set before or after `start()`. Switching the tap off
    /// takes effect before the next event; the system also echoes the switch-off as a
    /// `tapDisabledByUserInput` report (see `onDisabled`).
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue, let tap = eventTap else { return }
            CGEvent.tapEnable(tap: tap, enable: isEnabled)
            Logger.debug("\(name) event tap \(isEnabled ? "enabled" : "disabled")")
        }
    }

    init(
        name: String,
        events: [CGEventType],
        tapLocation: CGEventTapLocation = .cghidEventTap,
        tapPlacement: CGEventTapPlacement = .headInsertEventTap,
        tapOptions: CGEventTapOptions = .defaultTap,
        onDisabled: ((CGEventType) -> Void)? = nil,
        handler: @escaping Handler
    ) {
        self.name = name
        self.eventsOfInterest = Self.mask(for: events)
        self.tapLocation = tapLocation
        self.tapPlacement = tapPlacement
        self.tapOptions = tapOptions
        self.onDisabled = onDisabled
        self.handler = handler
    }

    var isRunning: Bool {
        eventTap != nil
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else {
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

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: isEnabled)
        Logger.debug("\(name) event tap started (enabled: \(isEnabled))")
        return true
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
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            // Let the owner settle its gesture state before the tap resumes receiving events. The
            // owner may switch the tap off in response, in which case it stays off.
            onDisabled?(type)
            if type == .tapDisabledByTimeout {
                Logger.keep("\(name) event tap timed out; \(isEnabled ? "re-enabling it" : "leaving it off")")
            }
            if isEnabled, let tap = eventTap {
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
