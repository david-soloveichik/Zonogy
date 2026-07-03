import CoreGraphics

/// Guardrail assertions for the pure window-focus navigation selection policy.
///
/// Frames are in the shared global coordinate space (y increases downward), mirroring the
/// accessibility coordinates AppController feeds the navigator at runtime.
///
/// Fixture: screen A holds a 2×2 tiled grid (zones 1–4: W1 top-left, W2 top-right, W3 bottom-left,
/// W4 bottom-right) plus floating window W5 sitting concentric over the grid. Screen B sits to the
/// right with one full-screen tile W6 and floating window W7. The overlapping float is the case the
/// pass-through rules exist for: it is the first stop in a direction that crosses it, and pressing
/// on moves relative to where it was entered from.
enum WindowFocusNavigationTests {
    private static let screenA: CGDirectDisplayID = 10
    private static let screenB: CGDirectDisplayID = 20

    private static func tiled(
        _ id: Int, zone: Int, _ frame: CGRect, on screenId: CGDirectDisplayID = screenA
    ) -> WindowFocusNavigation.Candidate {
        .init(windowId: id, frame: frame, screenId: screenId, isFloating: false, zoneIndex: zone)
    }

    private static func floating(
        _ id: Int, _ frame: CGRect, on screenId: CGDirectDisplayID = screenA
    ) -> WindowFocusNavigation.Candidate {
        .init(windowId: id, frame: frame, screenId: screenId, isFloating: true, zoneIndex: nil)
    }

    private static let w1 = tiled(1, zone: 1, CGRect(x: 0, y: 0, width: 480, height: 480))
    private static let w2 = tiled(2, zone: 2, CGRect(x: 520, y: 0, width: 480, height: 480))
    private static let w3 = tiled(3, zone: 3, CGRect(x: 0, y: 520, width: 480, height: 480))
    private static let w4 = tiled(4, zone: 4, CGRect(x: 520, y: 520, width: 480, height: 480))
    private static let w5 = floating(5, CGRect(x: 250, y: 250, width: 500, height: 500))

    private static let w6 = tiled(6, zone: 1, CGRect(x: 1000, y: 0, width: 1000, height: 1000), on: screenB)
    private static let w7 = floating(7, CGRect(x: 1250, y: 250, width: 500, height: 500), on: screenB)

    private static let singleScreen = [w1, w2, w3, w4, w5]
    private static let twoScreens = [w1, w2, w3, w4, w5, w6, w7]

    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertSel(_ actual: WindowFocusNavigation.Selection?, _ expected: Int?, _ label: String) {
            if actual?.windowId != expected {
                print("WindowFocusNavigationTests: \(label) failed\n  expected: \(expected.map(String.init) ?? "nil")\n  actual:   \(actual.map { String($0.windowId) } ?? "nil")")
                allPassed = false
            }
        }

        // A nil direction asserts the selection has no entry at all (Entry.direction is non-optional).
        func assertEntry(
            _ actual: WindowFocusNavigation.Selection?,
            windowId: Int?,
            direction: ZoneNavigationDirection?,
            _ label: String
        ) {
            if actual?.entry?.windowId != windowId || actual?.entry?.direction != direction {
                print("WindowFocusNavigationTests: \(label) failed\n  expected entry: windowId \(windowId.map(String.init) ?? "nil"), direction \(direction.map { String(describing: $0) } ?? "nil")\n  actual entry:   windowId \(actual?.entry?.windowId.map(String.init) ?? "nil"), direction \(actual?.entry.map { String(describing: $0.direction) } ?? "nil")")
                allPassed = false
            }
        }

        func anchor(at candidate: WindowFocusNavigation.Candidate) -> WindowFocusNavigation.Anchor {
            .init(frame: candidate.frame, screenId: candidate.screenId)
        }

        func initial(
            _ direction: ZoneNavigationDirection,
            focused: WindowFocusNavigation.Candidate? = nil,
            anchor: WindowFocusNavigation.Anchor,
            targetOccupant: Int? = nil,
            candidates: [WindowFocusNavigation.Candidate] = singleScreen
        ) -> WindowFocusNavigation.Selection? {
            WindowFocusNavigation.initialSelection(
                direction: direction,
                focusedWindowId: focused?.windowId,
                anchor: anchor,
                targetOccupantWindowId: targetOccupant,
                candidates: candidates
            )
        }

        func next(
            _ direction: ZoneNavigationDirection,
            from selection: WindowFocusNavigation.Selection?,
            anchor: WindowFocusNavigation.Anchor,
            candidates: [WindowFocusNavigation.Candidate] = singleScreen
        ) -> WindowFocusNavigation.Selection? {
            WindowFocusNavigation.nextSelection(
                direction: direction,
                currentSelection: selection,
                anchor: anchor,
                candidates: candidates
            )
        }

        // MARK: The overlapping float is the first stop of any crossing (vertical and horizontal),
        // and a directional arrival records its source as the entry.
        let upFromW3 = initial(.up, focused: w3, anchor: anchor(at: w3))
        assertSel(upFromW3, w5.windowId, "cross: up W3→float")
        assertEntry(upFromW3, windowId: w3.windowId, direction: .up, "cross: up W3→float records entry")
        let upFromW4 = initial(.up, focused: w4, anchor: anchor(at: w4))
        assertSel(upFromW4, w5.windowId, "cross: up W4→float")
        let rightFromW3 = initial(.right, focused: w3, anchor: anchor(at: w3))
        assertSel(rightFromW3, w5.windowId, "cross: right W3→float")

        // MARK: Continuing in the entry direction passes beyond the float, remembering the column
        // or row it was entered from.
        assertSel(next(.up, from: upFromW3, anchor: anchor(at: w3)), w1.windowId, "pass-through: W3→float→up→W1")
        assertSel(next(.up, from: upFromW4, anchor: anchor(at: w4)), w2.windowId, "pass-through: W4→float→up→W2")
        assertSel(next(.right, from: rightFromW3, anchor: anchor(at: w3)), w4.windowId, "pass-through: W3→float→right→W4")

        // MARK: Reversing the entry direction backs out to the entry window (clearing the entry);
        // other directions move relative to it; dead directions stay on the float.
        let reversed = next(.down, from: upFromW3, anchor: anchor(at: w3))
        assertSel(reversed, w3.windowId, "reverse: W3→float→down→W3")
        assertEntry(reversed, windowId: nil, direction: nil, "reverse: backing out clears the entry")
        assertSel(next(.right, from: upFromW3, anchor: anchor(at: w3)), w4.windowId, "perpendicular: W3→float→right→W4")
        assertSel(next(.left, from: upFromW3, anchor: anchor(at: w3)), w5.windowId, "dead direction: W3→float→left stays on float")

        // MARK: A float selected without a directional entry (focused, or marked as the targeted
        // occupant) navigates from its own rectangle; exact ties prefer the lower zone index.
        assertSel(initial(.up, focused: w5, anchor: anchor(at: w5)), w1.windowId, "focused float: up → W1 (zone tie-break)")
        let markedFloat = initial(.left, anchor: anchor(at: w5), targetOccupant: w5.windowId)
        assertSel(markedFloat, w5.windowId, "filled floating target: first press marks the float")
        assertEntry(markedFloat, windowId: nil, direction: nil, "filled floating target: marking records no entry")
        assertSel(next(.up, from: markedFloat, anchor: anchor(at: w5)), w1.windowId, "marked float: up → W1")

        // MARK: Entering the float from an empty targeted zone's rectangle also records the entry
        // (with no entry window), so the entry direction still passes through while its reverse
        // stays on the float rather than jumping past where the gesture came from.
        let upFromAnchor = initial(.up, anchor: anchor(at: w3))
        assertSel(upFromAnchor, w5.windowId, "empty target: up anchor→float")
        assertEntry(upFromAnchor, windowId: nil, direction: .up, "empty target: entry records the anchor move")
        assertSel(next(.up, from: upFromAnchor, anchor: anchor(at: w3)), w1.windowId, "empty target: anchor→float→up→W1")
        assertSel(next(.down, from: upFromAnchor, anchor: anchor(at: w3)), w5.windowId, "empty target: reverse with no entry window stays on float")

        // MARK: No focus, filled targeted tiling zone — first press marks the occupant.
        assertSel(initial(.left, anchor: anchor(at: w2), targetOccupant: w2.windowId), w2.windowId, "filled-target: left marks W2")

        // MARK: Tiled moves are unchanged: nearest in the pressed direction, staying put at edges.
        assertSel(next(.right, from: initial(.left, anchor: anchor(at: w4), targetOccupant: w4.windowId), anchor: anchor(at: w4)), w4.windowId, "next: right W4→edge stays W4")
        assertSel(initial(.right, focused: w4, anchor: anchor(at: w4), candidates: twoScreens), w6.windowId, "cross-screen: right W4→W6")

        // MARK: No filled windows — nothing is selectable.
        assertSel(initial(.right, anchor: anchor(at: w1), candidates: []), nil, "empty candidates → nil")

        if allPassed {
            print("WindowFocusNavigationTests: all tests passed")
        }
        return allPassed
    }
}
