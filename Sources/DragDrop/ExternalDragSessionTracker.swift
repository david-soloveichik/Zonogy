/// Recognizes a live external (non-Zonogy) drag from the global mouse monitors while touching the
/// drag pasteboard as little as possible: reading its change count is a round trip to the
/// pasteboard server and the monitors see every drag event in every app, so the count is polled
/// sparingly and a session's content is judged once, as soon as it has landed. Pure state,
/// guardrail-tested.
import Foundation

struct ExternalDragSessionTracker {
    /// For this long after a gesture's first read, every drag or modifier event reads the change
    /// count again: the source app starts its drag session within the first few drag events, and a
    /// short drag can be over before a throttled read would look again.
    static let initialPollWindow: TimeInterval = 0.05

    /// After the initial window, the change count is read at most this often while the gesture has
    /// no recognized drag session yet, or its content has not landed. Reads happen only as drag or
    /// modifier events arrive, so a fresh external drag is recognized at the first event this long
    /// after the previous read.
    static let changeCountPollInterval: TimeInterval = 0.1

    /// The drag pasteboard keeps its content after a drag ends, so content alone cannot tell a live
    /// external drag from a leftover; a change count that differs from this one under a held button
    /// is the signal that a fresh drag session has started.
    private var handledChangeCount: Int
    private var firstPollTime: Date?
    private var lastPollTime: Date?
    /// The current gesture's drag session once its change count has been seen, with whether its
    /// content is something Zonogy can accept, or nil while the pasteboard is still empty: the count
    /// can change before the source's content lands (Mail's drags show an empty pasteboard at
    /// first). Once judged, the content is not examined again before the button is released.
    private var session: (changeCount: Int, isAcceptable: Bool?)?

    init(handledChangeCount: Int) {
        self.handledChangeCount = handledChangeCount
    }

    /// True while the current gesture is a recognized external drag whose content Zonogy accepts.
    var isLiveExternalDrag: Bool {
        session?.isAcceptable == true
    }

    /// True once the current gesture's drag session has been recognized, whatever its content.
    var hasSession: Bool {
        session != nil
    }

    /// True from a gesture's first poll until `endGesture`. Seeing the button up while this is
    /// true means the gesture's mouse-up was missed.
    var isTrackingGesture: Bool {
        firstPollTime != nil
    }

    /// Whether the caller should read the change count now.
    func shouldPollChangeCount(now: Date) -> Bool {
        // Nothing further to poll once a session's content has been judged.
        guard session?.isAcceptable == nil else {
            return false
        }
        guard let firstPollTime, let lastPollTime else {
            return true
        }
        if now.timeIntervalSince(firstPollTime) < Self.initialPollWindow {
            return true
        }
        return now.timeIntervalSince(lastPollTime) >= Self.changeCountPollInterval
    }

    /// Records a change-count read. `acceptability` is consulted only when the count reveals a fresh
    /// session: it says whether the content is acceptable, or nil while the pasteboard is still
    /// empty, which keeps polling.
    mutating func recordPoll(changeCount: Int, now: Date, acceptability: () -> Bool?) {
        if firstPollTime == nil {
            firstPollTime = now
        }
        lastPollTime = now
        guard changeCount != handledChangeCount else {
            return
        }
        session = (changeCount, acceptability())
    }

    /// The gesture ended (mouse-up) or was cancelled (Escape): its pasteboard content is now a
    /// leftover to ignore, and the next gesture starts polling afresh.
    mutating func endGesture(changeCount: Int) {
        handledChangeCount = changeCount
        session = nil
        firstPollTime = nil
        lastPollTime = nil
    }
}
