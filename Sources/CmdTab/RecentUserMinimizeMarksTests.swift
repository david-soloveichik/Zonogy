import AppKit

/// Guardrail tests for the just-minimized mark bookkeeping (timestamps + dismissal gestures).
enum RecentUserMinimizeMarksTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("RecentUserMinimizeMarksTests: \(message)")
                allPassed = false
            }
        }

        let start = Date(timeIntervalSinceReferenceDate: 1000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        // Timestamp mechanism: active within the settle delay, expired after it.
        do {
            var marks = RecentUserMinimizeMarks()
            marks.recordMinimize(windowId: 1, heldModifiers: [], now: at(0))
            assert(!marks.hasActiveGesture, "modifier-less minimize should not start a gesture")
            assert(marks.activeSkipWindowIds(now: at(2), settleDelay: 3) == [1], "mark should be active within the delay")
            assert(marks.activeSkipWindowIds(now: at(4), settleDelay: 3).isEmpty, "mark should expire after the delay")
        }

        // Gesture mechanism: outlives the delay while modifiers stay held, then only timestamps count.
        do {
            var marks = RecentUserMinimizeMarks()
            marks.recordMinimize(windowId: 1, heldModifiers: [.command], now: at(0))
            assert(marks.hasActiveGesture, "minimize with modifiers held should start a gesture")
            assert(
                marks.activeSkipWindowIds(now: at(10), settleDelay: 3) == [1],
                "gesture should keep the mark active past the settle delay"
            )
            marks.modifiersChanged(to: [.command, .shift])
            assert(marks.hasActiveGesture, "adding modifiers should not end the gesture")
            marks.modifiersChanged(to: [.shift])
            assert(!marks.hasActiveGesture, "releasing a required modifier should end the gesture")
            assert(
                marks.activeSkipWindowIds(now: at(10), settleDelay: 3).isEmpty,
                "after the gesture ends, an expired mark should be inactive"
            )
        }

        // Releasing one modifier of a combination ends that gesture.
        do {
            var marks = RecentUserMinimizeMarks()
            marks.recordMinimize(windowId: 1, heldModifiers: [.control, .command], now: at(0))
            marks.modifiersChanged(to: [.command])
            assert(!marks.hasActiveGesture, "dropping to a subset should end the gesture")
        }

        // Several minimizes during one held gesture accumulate and stay active while held.
        do {
            var marks = RecentUserMinimizeMarks()
            marks.recordMinimize(windowId: 1, heldModifiers: [.command], now: at(0))
            marks.recordMinimize(windowId: 2, heldModifiers: [.command], now: at(1))
            assert(
                marks.activeSkipWindowIds(now: at(10), settleDelay: 3) == [1, 2],
                "both gesture minimizes should stay active while held"
            )
        }

        // After release, recent marks remain active via their timestamps.
        do {
            var marks = RecentUserMinimizeMarks()
            marks.recordMinimize(windowId: 1, heldModifiers: [.command], now: at(0))
            marks.recordMinimize(windowId: 2, heldModifiers: [.command], now: at(1))
            marks.modifiersChanged(to: [])
            assert(
                marks.activeSkipWindowIds(now: at(2), settleDelay: 3) == [1, 2],
                "recent marks should stay active on timestamps after release"
            )
        }

        // Gesture lifetimes are independent per window: each mark persists while the modifiers
        // held during its own minimize remain held.
        do {
            var marks = RecentUserMinimizeMarks()
            marks.recordMinimize(windowId: 1, heldModifiers: [.command], now: at(0))
            marks.recordMinimize(windowId: 2, heldModifiers: [.control, .command], now: at(1))
            marks.modifiersChanged(to: [.command])
            assert(marks.gestureWindowIds == [1], "releasing Control should end only the Control-Command gesture")
            assert(
                marks.activeSkipWindowIds(now: at(10), settleDelay: 3) == [1],
                "the Command-only mark should stay skipped while Command is held"
            )
            marks.modifiersChanged(to: [])
            assert(!marks.hasActiveGesture, "releasing everything should end all gestures")
        }

        // A re-record of a still-marked window (the delayed miniaturize notification) refreshes
        // the timestamp but must not resurrect or redefine a gesture that already ended.
        do {
            var marks = RecentUserMinimizeMarks()
            marks.recordMinimize(windowId: 1, heldModifiers: [.control, .command], now: at(0))
            marks.modifiersChanged(to: [.command])
            assert(!marks.hasActiveGesture, "releasing Control should end the dismissal gesture")
            marks.recordMinimize(windowId: 1, heldModifiers: [.command], now: at(0.3))
            assert(!marks.hasActiveGesture, "the delayed re-record must not restart the gesture")
            assert(
                marks.activeSkipWindowIds(now: at(3.2), settleDelay: 3) == [1],
                "the re-record should refresh the mark's timestamp"
            )
        }

        // After a mark is cleared, a fresh minimize is a new dismissal and starts a new gesture.
        do {
            var marks = RecentUserMinimizeMarks()
            marks.recordMinimize(windowId: 1, heldModifiers: [.command], now: at(0))
            marks.clearMark(windowId: 1)
            marks.recordMinimize(windowId: 1, heldModifiers: [.command], now: at(5))
            assert(marks.hasActiveGesture, "a re-minimize after restore should start a fresh gesture")
        }

        // Clearing and consuming.
        do {
            var marks = RecentUserMinimizeMarks()
            marks.recordMinimize(windowId: 1, heldModifiers: [.command], now: at(0))
            marks.recordMinimize(windowId: 2, heldModifiers: [.command], now: at(0))
            marks.clearMark(windowId: 1)
            assert(
                marks.activeSkipWindowIds(now: at(1), settleDelay: 3) == [2],
                "clearMark should drop the window from both mechanisms"
            )
            marks.removeAll()
            assert(!marks.hasActiveGesture, "removeAll should end all gestures")
            assert(marks.activeSkipWindowIds(now: at(1), settleDelay: 3).isEmpty, "removeAll should drop every mark")
        }

        if allPassed {
            print("RecentUserMinimizeMarksTests: all tests passed")
        }
        return allPassed
    }
}
