import Foundation

/// Guardrail tests for `ManualDragGatePolicy`: the gesture-ownership gate for manual-drag
/// detection and when a candidate's moves start the drag.
enum ManualDragGatePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ManualDragGatePolicyTests: \(message)")
                allPassed = false
            }
        }

        func gate(
            windowId: Int = 1,
            blocked: Bool = false,
            cursorActive: Bool = false,
            current: Int? = nil
        ) -> ManualDragGatePolicy.Gate {
            ManualDragGatePolicy.gate(
                windowId: windowId,
                blockedUntilMouseUp: blocked,
                cursorDrivenDragActive: cursorActive,
                currentDraggingWindowId: current
            )
        }

        assert(gate() == .mayBecomeCandidate, "a clean gesture state should allow candidacy")
        assert(gate(blocked: true) == .blocked, "a block through mouse-up should block every window")
        assert(gate(cursorActive: true) == .blocked, "an active cursor-driven row drag should block every window")
        assert(gate(current: 1) == .continueCurrentDrag, "the window with the live drag should continue it")
        assert(gate(current: 2) == .blocked, "another window's live drag should block candidacy")
        assert(gate(blocked: true, current: 1) == .blocked, "the block should outrank even the live drag's continuation")

        // Where a candidate's movement counts from, and when it starts the drag.
        let zone = CGRect(x: 53, y: 41, width: 1451, height: 933)
        func origin(candidate: CGRect?, previous: CGRect?, frame: CGRect) -> CGRect {
            ManualDragGatePolicy.candidateOrigin(candidateOrigin: candidate, previousFrame: previous, frame: frame)
        }
        func starts(candidate: CGRect?, previous: CGRect?, frame: CGRect) -> Bool {
            let from = origin(candidate: candidate, previous: previous, frame: frame)
            return ManualDragGatePolicy.startsDrag(origin: from, frame: frame, threshold: 6)
        }
        assert(
            starts(candidate: nil, previous: zone, frame: zone.offsetBy(dx: -629, dy: -8)),
            "a single same-size report should start the drag (macOS may report nothing more across displays)"
        )
        assert(!starts(candidate: nil, previous: zone, frame: zone.offsetBy(dx: 2, dy: 1)), "a move under the threshold should not start the drag")
        assert(origin(candidate: nil, previous: nil, frame: zone) == zone, "without an earlier frame the report should be the origin")
        assert(
            origin(candidate: zone, previous: zone.offsetBy(dx: -3, dy: 0), frame: zone.offsetBy(dx: -5, dy: 0)) == zone,
            "a candidate's origin should be kept while the size is unchanged"
        )
        let leftResize = CGRect(x: 13, y: 41, width: 1491, height: 933)
        let furtherLeftResize = CGRect(x: -27, y: 41, width: 1531, height: 933)
        assert(!starts(candidate: nil, previous: zone, frame: leftResize), "a left-edge resize report should not start a drag")
        assert(!starts(candidate: leftResize, previous: leftResize, frame: furtherLeftResize), "a continuing left-edge resize should not start a drag")
        let cornerResize = CGRect(x: 23, y: 11, width: 1481, height: 963)
        assert(!starts(candidate: zone, previous: zone, frame: cornerResize), "a top-left corner resize should not start a drag")
        let shrunk = CGRect(x: 50, y: 41, width: 1351, height: 833)
        assert(origin(candidate: zone, previous: zone, frame: shrunk) == shrunk, "a size change should restart the candidate from the new frame")
        assert(starts(candidate: shrunk, previous: shrunk, frame: shrunk.offsetBy(dx: -20, dy: 0)), "same-size moves after a size change should start the drag")
        assert(!starts(candidate: shrunk, previous: shrunk, frame: shrunk), "repeated frames at a new size should not start the drag")
        assert(
            origin(candidate: zone, previous: shrunk, frame: shrunk.offsetBy(dx: -4, dy: 0)) == shrunk,
            "after a size change reported by a resize, movement should count from the resized frame"
        )
        assert(
            !starts(candidate: zone, previous: zone.insetBy(dx: -50, dy: 0), frame: zone.offsetBy(dx: 20, dy: 0)),
            "a size change in between should restart the count even when the size returns"
        )
        assert(
            starts(candidate: zone, previous: zone.offsetBy(dx: 3, dy: 0), frame: zone.offsetBy(dx: 7, dy: 0)),
            "movement under the threshold per report should add up to start the drag"
        )

        if allPassed {
            print("ManualDragGatePolicyTests: all tests passed")
        }
        return allPassed
    }
}
