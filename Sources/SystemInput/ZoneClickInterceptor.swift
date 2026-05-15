import Foundation
import ApplicationServices

/// Intercepts global left-clicks so zones can be retargeted without delivering the click
/// to the underlying application. The delegate decides, based on current state (modifier
/// keys, CmdTab visibility, etc), whether a given click should be consumed.
protocol ZoneClickInterceptorDelegate: AnyObject {
    /// - Returns: true if the gesture was handled and the click should be swallowed.
    func zoneClickInterceptor(
        _ interceptor: ZoneClickInterceptor,
        shouldConsumeClickAt location: CGPoint,
        modifiers: CGEventFlags
    ) -> Bool
}

final class ZoneClickInterceptor {
    weak var delegate: ZoneClickInterceptorDelegate?

    private var eventTap: EventTapController?

    func start(delegate: ZoneClickInterceptorDelegate) {
        self.delegate = delegate

        guard eventTap == nil else {
            Logger.debug("Zone click interceptor already running")
            return
        }

        let tap = EventTapController(
            name: "zone click interceptor",
            events: [.leftMouseDown],
            handler: { [weak self] type, event in
                self?.processEvent(event, type: type) ?? .pass
            }
        )
        if tap.start() {
            eventTap = tap
        }
    }

    func stop() {
        eventTap?.stop()
        eventTap = nil
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> EventTapDecision {
        guard type == .leftMouseDown else {
            return .pass
        }

        guard let delegate else {
            return .pass
        }

        let location = event.location
        if delegate.zoneClickInterceptor(self, shouldConsumeClickAt: location, modifiers: event.flags) {
            return .swallow
        }

        return .pass
    }
}
