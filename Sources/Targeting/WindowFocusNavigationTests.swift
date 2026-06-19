import CoreGraphics

/// Guardrail assertions for the pure window-focus navigation selection policy.
///
/// Frames are in the shared global coordinate space (y increases downward), mirroring the
/// accessibility coordinates AppController feeds the navigator at runtime.
enum WindowFocusNavigationTests {
    private static let screen: CGDirectDisplayID = 10

    /// W1 top-left, W2 to its right, W3 below it. A bottom bar models an empty floating-zone anchor.
    private static let w1 = WindowFocusNavigation.Candidate(windowId: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), screenId: screen)
    private static let w2 = WindowFocusNavigation.Candidate(windowId: 2, frame: CGRect(x: 200, y: 0, width: 100, height: 100), screenId: screen)
    private static let w3 = WindowFocusNavigation.Candidate(windowId: 3, frame: CGRect(x: 0, y: 200, width: 100, height: 100), screenId: screen)
    private static let candidates = [w1, w2, w3]
    private static let floatingBar = CGRect(x: 0, y: 400, width: 100, height: 6)

    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ actual: Int?, _ expected: Int?, _ label: String) {
            if actual != expected {
                print("WindowFocusNavigationTests: \(label) failed\n  expected: \(expected.map(String.init) ?? "nil")\n  actual:   \(actual.map(String.init) ?? "nil")")
                allPassed = false
            }
        }

        func initial(
            _ direction: ZoneNavigationDirection,
            focused: Int? = nil,
            anchor: CGRect,
            targetOccupant: Int? = nil,
            candidates: [WindowFocusNavigation.Candidate] = candidates
        ) -> Int? {
            WindowFocusNavigation.initialSelection(
                direction: direction,
                focusedWindowId: focused,
                anchorFrame: anchor,
                anchorScreenId: screen,
                targetOccupantWindowId: targetOccupant,
                candidates: candidates
            )
        }

        func next(_ direction: ZoneNavigationDirection, from selection: Int?, anchor: CGRect) -> Int? {
            WindowFocusNavigation.nextSelection(
                direction: direction,
                currentSelection: selection,
                anchorFrame: anchor,
                anchorScreenId: screen,
                candidates: candidates
            )
        }

        // MARK: Focused window — first press moves off it.
        assert(initial(.right, focused: w1.windowId, anchor: w1.frame), w2.windowId, "focused: right W1→W2")
        assert(initial(.down, focused: w1.windowId, anchor: w1.frame), w3.windowId, "focused: down W1→W3")
        assert(initial(.left, focused: w1.windowId, anchor: w1.frame), nil, "focused: left W1→edge")
        assert(initial(.up, focused: w1.windowId, anchor: w1.frame), nil, "focused: up W1→edge")

        // MARK: No focus, empty targeted zone — first press moves directionally from its rectangle.
        assert(initial(.up, anchor: floatingBar), w3.windowId, "empty-target: up bar→W3 (nearer)")

        // MARK: No focus, filled targeted zone — first press marks the occupant, ignoring direction.
        assert(initial(.left, anchor: w2.frame, targetOccupant: w2.windowId), w2.windowId, "filled-target: left marks W2")
        assert(initial(.right, anchor: w2.frame, targetOccupant: w2.windowId), w2.windowId, "filled-target: right marks W2")

        // MARK: Subsequent presses move from the current selection (and stay put at an edge).
        assert(next(.left, from: w2.windowId, anchor: w2.frame), w1.windowId, "next: left W2→W1")
        assert(next(.down, from: w2.windowId, anchor: w2.frame), w3.windowId, "next: down W2→W3")
        assert(next(.right, from: w2.windowId, anchor: w2.frame), w2.windowId, "next: right W2→edge stays W2")

        // MARK: Subsequent press with no selection yet navigates from the fixed anchor.
        assert(next(.up, from: nil, anchor: floatingBar), w3.windowId, "next: up from anchor bar→W3")

        // MARK: No filled windows — nothing is selectable.
        assert(initial(.right, anchor: floatingBar, candidates: []), nil, "empty candidates → nil")

        if allPassed {
            print("WindowFocusNavigationTests: all tests passed")
        }
        return allPassed
    }
}
