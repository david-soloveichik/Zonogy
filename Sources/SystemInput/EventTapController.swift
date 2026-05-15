/// Owns the common lifecycle for a swallowing CGEventTap.

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
    private let onDisabled: ((CGEventType) -> Void)?
    private let handler: Handler

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
            Logger.debug("Failed to install \(name) event tap (missing Input Monitoring permission?)")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.debug("\(name) event tap started")
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
            // Let owners clear gesture state before the tap resumes receiving events.
            onDisabled?(type)
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.debug("Re-enabled \(name) event tap after timeout")
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
