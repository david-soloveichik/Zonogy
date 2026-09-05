/// Recognizes a live external (non-Zonogy) drag from the global mouse monitors while touching the
/// drag pasteboard as little as possible: reading its change count is a round trip to the
/// pasteboard server and the monitors see every drag event in every app, so the count is polled
/// sparingly and a recognized session's content is examined once. Pure state, guardrail-tested.
import Foundation

struct ExternalDragSessionTracker {
    /// For this long after a gesture's first read, every drag or modifier event reads the change
    /// count again: the source app starts its drag session within the first few drag events, and a
    /// short drag can be over before a throttled read would look again.
    static let initialPollWindow: TimeInterval = 0.05

    /// After the initial window, the change count is read at most this often while the gesture has
    /// no recognized drag session yet. Reads happen only as drag or modifier events arrive, so a
    /// fresh external drag is recognized at the first event this long after the previous read.
    static let changeCountPollInterval: TimeInterval = 0.1

    /// The drag pasteboard keeps its content after a drag ends, so content alone cannot tell a live
    /// external drag from a leftover; a change count that differs from this one under a held button
    /// is the signal that a fresh drag session has started.
    private var handledChangeCount: Int
    private var firstPollTime: Date?
    private var lastPollTime: Date?
    /// The current gesture's drag session once its change count has been seen, with whether its
    /// content is something Zonogy can accept. A session's content cannot change until the button
    /// is released, so once set there is nothing further to poll.
    private var session: (changeCount: Int, isAcceptable: Bool)?

    init(handledChangeCount: Int) {
        self.handledChangeCount = handledChangeCount
    }

    /// True while the current gesture is a recognized external drag whose content Zonogy accepts.
    var isLiveExternalDrag: Bool {
        session?.isAcceptable == true
    }

    /// True once the current gesture's drag session has been recognized, acceptable or not.
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
        guard session == nil else {
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

    /// Records a change-count read. `isAcceptable` is consulted, once, only when the count reveals
    /// a fresh session.
    mutating func recordPoll(changeCount: Int, now: Date, isAcceptable: () -> Bool) {
        if firstPollTime == nil {
            firstPollTime = now
        }
        lastPollTime = now
        guard changeCount != handledChangeCount else {
            return
        }
        session = (changeCount, isAcceptable())
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
