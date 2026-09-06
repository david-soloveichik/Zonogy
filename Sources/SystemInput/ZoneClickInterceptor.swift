/// Intercepts global left-clicks so zones can be retargeted without delivering the click to the
/// underlying application. The delegate decides, based on current state (modifier keys, CmdTab
/// visibility, etc), whether a given click should be consumed.
///
/// The tap is serviced by its own thread. Nearly every click concerns only the app under the
/// cursor: while the WinShot chooser shows every click passes, and otherwise, with CmdTab hidden and
/// the gesture modifiers not held, the callback passes the click at once, so ordinary clicks never
/// wait on Zonogy's main thread. Only the remaining clicks are handed to the delegate on the main
/// thread, synchronously, because whether to consume one depends on zone geometry and window frames
/// that live there.

import Foundation
import ApplicationServices

protocol ZoneClickInterceptorDelegate: AnyObject {
    /// Called on the main thread while the system waits for the click's fate.
    /// - Parameter clickCount: WindowServer-tracked click state on this mouse-down (1 for single,
    ///   2 for second click within the system double-click window at the same location, etc).
    /// - Returns: true if the gesture was handled and the click should be swallowed.
    func zoneClickInterceptor(
        _ interceptor: ZoneClickInterceptor,
        shouldConsumeClickAt location: CGPoint,
        modifiers: CGEventFlags,
        clickCount: Int
    ) -> Bool
}

final class ZoneClickInterceptor {
    weak var delegate: ZoneClickInterceptorDelegate?

    private var eventTap: EventTapController?

    /// Chooser state mirrored for the tap thread. While the WinShot chooser shows, every click
    /// passes; while CmdTab shows, every click is the delegate's. The delegate re-checks both, so a
    /// mirror that lags by a moment costs nothing but a main-thread hop or a passed click.
    @ThreadSafe var isCmdTabActive = false
    @ThreadSafe var isWinShotChooserActive = false

    func start(delegate: ZoneClickInterceptorDelegate) {
        self.delegate = delegate

        guard eventTap == nil else {
            Logger.debug("Zone click interceptor already running")
            return
        }

        let tap = EventTapController(
            name: "zone click interceptor",
            events: [.leftMouseDown],
            runLoop: EventTapThread.mouse.runLoop,
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
        guard type == .leftMouseDown, !isWinShotChooserActive else {
            return .pass
        }

        // With CmdTab hidden, only a gesture-modifier click (Control-Command by default) can be
        // Zonogy's; everything else passes here, without involving the main thread.
        let modifiers = event.flags
        guard isCmdTabActive || modifiers.contains(ModifierCombinationPreferences.mouseGestures.modifiers.cgEventFlags) else {
            return .pass
        }

        let location = event.location
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        let consume = MainRunLoop.performAndWait {
            self.delegate?.zoneClickInterceptor(self, shouldConsumeClickAt: location, modifiers: modifiers, clickCount: clickCount) ?? false
        }
        return consume ? .swallow : .pass
    }
}
