/// Takes over left-button gestures that begin on a press its claimant claims: the press and every
/// event through its release are swallowed, so the UI under the cursor never sees the gesture, and
/// the claimant hears whether it was a click or a drag.
import ApplicationServices
import Foundation

/// Decides which presses a `PressGestureInterceptor` takes over, and hears how each gesture ends.
protocol PressGestureClaimant: AnyObject {
    /// What the claimant keeps about a press it takes over.
    associatedtype Claim

    /// On the mouse tap thread, for every left mouse-down while the press tap is enabled: whether
    /// the press may be one to take over. Must be cheap; false passes the press at once, without
    /// involving the main thread.
    func mayClaimPress(_ event: CGEvent) -> Bool

    /// On the main thread while the press waits: the claim on a press to take over, or nil to let
    /// the press through.
    func claimPress(_ event: CGEvent) -> Claim?

    /// The cursor moved past the drag threshold. True follows the drag; false swallows the rest of
    /// the gesture without further calls.
    func beginDrag(of claim: Claim, at point: CGPoint) -> Bool

    func updateDrag(to point: CGPoint)

    func endDrag(at point: CGPoint)

    /// The drag in flight ended without its release: a tap timed out, so the release may have
    /// passed unseen. Nothing is dropped.
    func abortDrag()

    /// The button came up without a drag. `release` is the mouse-up, which is swallowed.
    func click(_ claim: Claim, release: CGEvent)

    /// Called after a taken-over gesture ends: its release was handled and swallowed, or the gesture
    /// was abandoned after its release passed unseen. No event monitor may see that mouse-up, so
    /// whatever waits for it must be told.
    func didSwallowRelease()
}

/// Performance-critical: separate event taps keep the system-wide cost down. The press tap answers
/// on the mouse tap thread, so a press the claimant turns away passes at once, and only a press it
/// may claim waits for the main thread. Claimants keep the press tap switched off while nothing
/// could be claimed. The drag and release taps run only between a claimed press and its release,
/// so ordinary drags anywhere else never wake Zonogy. Both stay on the main run loop, where the
/// gesture state lives. All positions are in accessibility coordinates.
final class PressGestureInterceptor<Claimant: PressGestureClaimant> {
    /// Movement in points, in either direction, that turns a press into a drag.
    private static var dragThreshold: CGFloat { 8 }

    private enum DragState {
        case none
        case intercepted
        /// A declined or cancelled drag: the rest of the gesture is swallowed without any action.
        case ignored
    }

    private struct Pending {
        let downLocation: CGPoint
        let claim: Claimant.Claim
        var dragState: DragState = .none
    }

    private let name: String
    private weak var claimant: Claimant?

    /// Whether the press tap sees left mouse-downs.
    var isPressTapEnabled = false {
        didSet {
            pressTap?.isEnabled = isPressTapEnabled
        }
    }

    private var pressTap: EventTapController?
    /// Sees drags; enabled only while a press is claimed.
    private var dragTap: EventTapController?
    /// Sees the release; enabled only while a press is claimed.
    private var releaseTap: EventTapController?

    private var pending: Pending? {
        didSet {
            dragTap?.isEnabled = pending != nil
            releaseTap?.isEnabled = pending != nil
        }
    }

    init(name: String, claimant: Claimant) {
        self.name = name
        self.claimant = claimant
    }

    func start() {
        guard pressTap == nil else {
            Logger.debug("\(name): already running")
            return
        }

        pending = nil

        let press = makeTap(
            name: "\(name) press", events: [.leftMouseDown],
            tapLocation: .cghidEventTap, runLoop: EventTapThread.mouse.runLoop
        ) { [weak self] _, event in
            self?.processPress(event) ?? .pass
        }
        // Let WindowServer update the cursor before swallowing movement, including during capture.
        let drag = makeTap(
            name: "\(name) drag", events: [.leftMouseDragged],
            tapLocation: .cgAnnotatedSessionEventTap, runLoop: CFRunLoopGetMain()
        ) { [weak self] _, event in
            self?.processDrag(event) ?? .pass
        }
        // The press was swallowed at HID, so its release may never reach the annotated tap.
        // Intercept the release at HID too, for both clicks and drags (including cancellation).
        let release = makeTap(
            name: "\(name) release", events: [.leftMouseUp],
            tapLocation: .cghidEventTap, runLoop: CFRunLoopGetMain()
        ) { [weak self] _, event in
            self?.processRelease(event) ?? .pass
        }
        press.isEnabled = isPressTapEnabled
        drag.isEnabled = false
        release.isEnabled = false
        guard press.start(), drag.start(), release.start() else {
            press.stop()
            drag.stop()
            release.stop()
            return
        }
        pressTap = press
        dragTap = drag
        releaseTap = release
    }

    func stop() {
        pending = nil
        pressTap?.stop()
        pressTap = nil
        dragTap?.stop()
        dragTap = nil
        releaseTap?.stop()
        releaseTap = nil
        Logger.debug("\(name): stopped")
    }

    /// Cancels the drag in flight (e.g., the user pressed Escape). Further drag updates are ignored
    /// and the eventual mouse-up is swallowed without ending the drag.
    func cancelInProgressDrag() {
        guard var pending, pending.dragState == .intercepted else {
            return
        }
        pending.dragState = .ignored
        self.pending = pending
        Logger.debug("\(name): in-progress drag marked cancelled (Escape)")
    }

    private func makeTap(
        name: String,
        events: [CGEventType],
        tapLocation: CGEventTapLocation,
        runLoop: CFRunLoop,
        handler: @escaping EventTapController.Handler
    ) -> EventTapController {
        EventTapController(
            name: name,
            events: events,
            tapLocation: tapLocation,
            runLoop: runLoop,
            onDisabled: { [weak self] type in
                // A user-input report is indistinguishable from the (possibly late) echo of switching
                // a tap off, so only a timeout is taken to mean the pending press cannot be trusted.
                // The pending press is main-thread state: the drag and release taps report on main and
                // abandon it at once (an abandonment queued behind a newer press would erase that
                // press), while the press tap reports on the mouse thread and hands it to main.
                guard type == .tapDisabledByTimeout else { return }
                if Thread.isMainThread {
                    self?.abandonPending()
                } else {
                    MainRunLoop.perform { self?.abandonPending() }
                }
            },
            handler: handler
        )
    }

    /// After a tap timed out, the release may already have passed unseen, so the pending gesture
    /// cannot be trusted: it ends here, a drag in flight without a drop. A release that passed unseen
    /// is reported now (the physical button is up); one still to come passes through unswallowed.
    private func abandonPending() {
        guard let abandoned = pending else { return }
        pending = nil
        if abandoned.dragState == .intercepted {
            Logger.debug("\(name): drag in flight abandoned after an event tap timed out")
            claimant?.abortDrag()
        }
        if !CGEventSource.buttonState(.hidSystemState, button: .left) {
            claimant?.didSwallowRelease()
        }
    }

    private static func isDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        abs(end.x - start.x) > dragThreshold || abs(end.y - start.y) > dragThreshold
    }

    /// The press tap's callback, on the mouse tap thread.
    private func processPress(_ event: CGEvent) -> EventTapDecision {
        guard claimant?.mayClaimPress(event) == true else {
            return .pass
        }
        return MainRunLoop.performAndWait {
            // The interceptor may have been stopped while this decision waited its turn.
            guard self.pressTap != nil, let claim = self.claimant?.claimPress(event) else {
                return .pass
            }
            self.pending = Pending(downLocation: event.location, claim: claim)
            return .swallow
        }
    }

    /// The drag tap's callback, on the main run loop: tells a drag from a click and follows a
    /// drag. Every drag of a claimed press is swallowed, so the UI under the cursor never reacts.
    private func processDrag(_ event: CGEvent) -> EventTapDecision {
        guard var pending else {
            return .pass
        }
        let location = event.location
        switch pending.dragState {
        case .intercepted:
            claimant?.updateDrag(to: location)
            return .swallow
        case .ignored:
            return .swallow
        case .none:
            break
        }

        // Within the threshold, the press is still a click.
        guard Self.isDrag(from: pending.downLocation, to: location) else {
            return .swallow
        }

        let accepted = claimant?.beginDrag(of: pending.claim, at: location) ?? false
        pending.dragState = accepted ? .intercepted : .ignored
        self.pending = pending
        if accepted {
            claimant?.updateDrag(to: location)
        }
        return .swallow
    }

    /// The release tap's callback, on the main run loop: finishes the claimed click or drag at the
    /// physical release location.
    private func processRelease(_ event: CGEvent) -> EventTapDecision {
        guard let pending else {
            return .pass
        }
        self.pending = nil

        // The UI under the cursor never received the press, so it has no tracking of its own to
        // finish. A synthetic mouse-up posted at the press location would move the cursor back there.
        switch pending.dragState {
        case .intercepted:
            claimant?.endDrag(at: event.location)
        case .none:
            // A release past the threshold whose movement the drag tap never saw is no click.
            if !Self.isDrag(from: pending.downLocation, to: event.location) {
                claimant?.click(pending.claim, release: event)
            }
        case .ignored:
            break
        }
        claimant?.didSwallowRelease()
        return .swallow
    }
}
