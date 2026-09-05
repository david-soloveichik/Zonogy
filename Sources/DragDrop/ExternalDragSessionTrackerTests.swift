import Foundation

/// Guardrail tests for how sparingly the drag pasteboard is polled and when a drag counts as live.
enum ExternalDragSessionTrackerTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ExternalDragSessionTrackerTests: \(message)")
                allPassed = false
            }
        }

        let burst = ExternalDragSessionTracker.initialPollWindow
        let interval = ExternalDragSessionTracker.changeCountPollInterval
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var acceptabilityChecks = 0

        // A fresh gesture polls at once and on every event inside the initial window, then only
        // once the throttle interval has elapsed since the last poll.
        var tracker = ExternalDragSessionTracker(handledChangeCount: 5)
        assert(tracker.shouldPollChangeCount(now: t0), "a gesture with no poll yet polls immediately")
        tracker.recordPoll(changeCount: 5, now: t0) { acceptabilityChecks += 1; return true }
        assert(acceptabilityChecks == 0, "an unchanged count (leftover content) never examines the pasteboard content")
        assert(!tracker.isLiveExternalDrag && !tracker.hasSession, "an unchanged count is not a drag session")
        assert(tracker.isTrackingGesture, "a gesture is tracked from its first poll even before any session is recognized")
        let secondEvent = t0.addingTimeInterval(burst / 2)
        assert(tracker.shouldPollChangeCount(now: secondEvent), "every event inside the initial window polls")
        tracker.recordPoll(changeCount: 5, now: secondEvent) { acceptabilityChecks += 1; return true }
        assert(!tracker.shouldPollChangeCount(now: t0.addingTimeInterval(burst * 1.5)), "after the initial window, no re-poll before the interval elapses")
        assert(!tracker.shouldPollChangeCount(now: secondEvent.addingTimeInterval(interval / 2)), "the throttle counts from the last poll")
        let throttledEvent = secondEvent.addingTimeInterval(interval)
        assert(tracker.shouldPollChangeCount(now: throttledEvent), "re-poll once the interval has elapsed since the last poll")

        // A new count is a fresh session; its content is examined once and never re-polled.
        tracker.recordPoll(changeCount: 6, now: throttledEvent) { acceptabilityChecks += 1; return true }
        assert(acceptabilityChecks == 1, "a fresh session examines the pasteboard content exactly once")
        assert(tracker.isLiveExternalDrag, "an acceptable fresh session is a live external drag")
        assert(!tracker.shouldPollChangeCount(now: t0.addingTimeInterval(60)), "a recognized session is never re-polled before the gesture ends")

        // Ending the gesture makes that count a leftover and restarts polling.
        tracker.endGesture(changeCount: 6)
        assert(!tracker.isLiveExternalDrag && !tracker.hasSession && !tracker.isTrackingGesture, "ending the gesture clears the session and the tracking")
        assert(tracker.shouldPollChangeCount(now: t0.addingTimeInterval(60)), "the next gesture polls immediately")
        tracker.recordPoll(changeCount: 6, now: t0.addingTimeInterval(60)) { acceptabilityChecks += 1; return true }
        assert(!tracker.isLiveExternalDrag && acceptabilityChecks == 1, "the ended session's count is a leftover, not a new session")

        // An unacceptable fresh session is recognized (so polling stops) but is not live.
        tracker.recordPoll(changeCount: 7, now: t0.addingTimeInterval(61)) { acceptabilityChecks += 1; return false }
        assert(acceptabilityChecks == 2, "an unacceptable fresh session is examined once")
        assert(tracker.hasSession && !tracker.isLiveExternalDrag, "an unacceptable session is recognized but not live")
        assert(!tracker.shouldPollChangeCount(now: t0.addingTimeInterval(120)), "an unacceptable session is not re-polled either")

        if allPassed {
            print("ExternalDragSessionTrackerTests: all tests passed")
        }
        return allPassed
    }
}
