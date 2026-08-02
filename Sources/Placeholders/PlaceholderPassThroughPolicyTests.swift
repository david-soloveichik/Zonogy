import Foundation
import CoreGraphics

/// Simple assertions for PlaceholderPassThroughPolicy behavior.
enum PlaceholderPassThroughPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertEqual(_ actual: [CGRect], _ expected: [CGRect], label: String) {
            guard actual == expected else {
                print("PlaceholderPassThroughPolicyTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
                return
            }
        }

        let zonogyPid: pid_t = 100
        let otherPid: pid_t = 200

        func row(
            _ windowNumber: Int,
            _ frame: CGRect,
            pid: pid_t = 200,
            layer: Int = 0,
            alpha: CGFloat = 1
        ) -> WindowServerWindowRow {
            WindowServerWindowRow(windowNumber: windowNumber, ownerPid: pid, layer: layer, alpha: alpha, frame: frame)
        }

        let placeholderFrame = CGRect(x: 100, y: 100, width: 400, height: 400)
        let placeholder = row(1, placeholderFrame, pid: zonogyPid)

        // Unmanaged window behind the placeholder → hole over the overlap.
        do {
            let unmanaged = row(2, CGRect(x: 300, y: 300, width: 400, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, unmanaged],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [CGRect(x: 300, y: 300, width: 200, height: 200)], label: "behind-overlapping")
        }

        // Same window in front of the placeholder → no hole.
        do {
            let unmanaged = row(2, CGRect(x: 300, y: 300, width: 400, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [unmanaged, placeholder],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [], label: "in-front-no-hole")
        }

        // Managed window behind → no hole.
        do {
            let managed = row(2, CGRect(x: 300, y: 300, width: 400, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, managed],
                zonogyPid: zonogyPid,
                managedCgWindowIds: [2]
            )
            assertEqual(holes, [], label: "managed-excluded")
        }

        // Zonogy's own window behind (another placeholder/overlay) → no hole.
        do {
            let ownWindow = row(2, CGRect(x: 300, y: 300, width: 400, height: 300), pid: zonogyPid)
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, ownWindow],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [], label: "own-pid-excluded")
        }

        // Non-normal-level window behind (e.g. a floating panel dipping under) → no hole.
        do {
            let floating = row(2, CGRect(x: 300, y: 300, width: 400, height: 300), layer: 3)
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, floating],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [], label: "non-normal-layer-excluded")
        }

        // Fully transparent window behind → no hole (clicks already pass through it).
        do {
            let invisible = row(2, CGRect(x: 300, y: 300, width: 400, height: 300), alpha: 0)
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, invisible],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [], label: "zero-alpha-excluded")
        }

        // Sliver overlap within the shadow-tolerance inset → no hole.
        do {
            let sliver = row(2, CGRect(x: 495, y: 100, width: 300, height: 400))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, sliver],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [], label: "sliver-overlap-ignored")
        }

        // Behind but not overlapping → no hole.
        do {
            let elsewhere = row(2, CGRect(x: 600, y: 100, width: 300, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, elsewhere],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [], label: "no-overlap-no-hole")
        }

        // Tiny window (smaller than the inset tolerance, e.g. a 1x1 focus proxy) → no hole.
        do {
            let tiny = row(2, CGRect(x: 200, y: 200, width: 8, height: 8))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, tiny],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [], label: "tiny-window-ignored")
        }

        // Two qualifying windows behind → two holes, in z-order (front first).
        do {
            let first = row(2, CGRect(x: 150, y: 150, width: 100, height: 100))
            let second = row(3, CGRect(x: 350, y: 350, width: 300, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, first, second],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(
                holes,
                [
                    CGRect(x: 150, y: 150, width: 100, height: 100),
                    CGRect(x: 350, y: 350, width: 150, height: 150)
                ],
                label: "two-holes"
            )
        }

        // Candidate fully covering the placeholder → hole equals the whole placeholder frame.
        do {
            let covering = row(2, CGRect(x: 0, y: 0, width: 1000, height: 1000))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, covering],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [placeholderFrame], label: "full-cover-full-hole")
        }

        // Placeholder missing from the z-order snapshot → no holes.
        do {
            let unmanaged = row(2, CGRect(x: 300, y: 300, width: 400, height: 300), pid: otherPid)
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [unmanaged],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [], label: "placeholder-missing")
        }

        // Mixed stack: one window in front, one behind, both overlapping → only the behind one punches.
        do {
            let inFront = row(2, CGRect(x: 120, y: 120, width: 100, height: 100))
            let behind = row(3, CGRect(x: 300, y: 300, width: 400, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [inFront, placeholder, behind],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [CGRect(x: 300, y: 300, width: 200, height: 200)], label: "mixed-stack")
        }

        // Managed window between placeholder and candidate blocks its part of the hole:
        // clicks there belong to the managed window's own surface, not the pass-through.
        do {
            let managedBetween = row(2, CGRect(x: 250, y: 250, width: 100, height: 300))
            let unmanaged = row(3, CGRect(x: 300, y: 300, width: 400, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, managedBetween, unmanaged],
                zonogyPid: zonogyPid,
                managedCgWindowIds: [2]
            )
            assertEqual(holes, [CGRect(x: 350, y: 300, width: 150, height: 200)], label: "managed-blocker-clips-hole")
        }

        // Blocker fully covering the candidate's overlap → no hole at all.
        do {
            let managedBetween = row(2, CGRect(x: 250, y: 250, width: 300, height: 300))
            let unmanaged = row(3, CGRect(x: 300, y: 300, width: 200, height: 200))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, managedBetween, unmanaged],
                zonogyPid: zonogyPid,
                managedCgWindowIds: [2]
            )
            assertEqual(holes, [], label: "blocker-covers-candidate")
        }

        // Blocker strictly inside the hole → four remainder pieces (top, bottom, left, right).
        do {
            let managedIsland = row(2, CGRect(x: 250, y: 250, width: 100, height: 100))
            let covering = row(3, CGRect(x: 0, y: 0, width: 1000, height: 1000))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, managedIsland, covering],
                zonogyPid: zonogyPid,
                managedCgWindowIds: [2]
            )
            assertEqual(
                holes,
                [
                    CGRect(x: 100, y: 100, width: 400, height: 150),
                    CGRect(x: 100, y: 350, width: 400, height: 150),
                    CGRect(x: 100, y: 250, width: 150, height: 100),
                    CGRect(x: 350, y: 250, width: 150, height: 100)
                ],
                label: "blocker-island"
            )
        }

        // A sliver that fails the overlap test still blocks deeper candidates: clicks over the
        // sliver would reach the sliver window, which was deliberately not made pass-through.
        do {
            let sliver = row(2, CGRect(x: 495, y: 100, width: 300, height: 400))
            let deep = row(3, CGRect(x: 300, y: 100, width: 400, height: 400))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, sliver, deep],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(holes, [CGRect(x: 300, y: 100, width: 195, height: 400)], label: "non-qualifying-sliver-blocks-deeper")
        }

        // Overlapping candidates: the nearer one blocks the deeper one, keeping regions disjoint.
        do {
            let near = row(2, CGRect(x: 150, y: 150, width: 100, height: 100))
            let deep = row(3, CGRect(x: 150, y: 150, width: 300, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, near, deep],
                zonogyPid: zonogyPid,
                managedCgWindowIds: []
            )
            assertEqual(
                holes,
                [
                    CGRect(x: 150, y: 150, width: 100, height: 100),
                    CGRect(x: 150, y: 250, width: 300, height: 200),
                    CGRect(x: 250, y: 150, width: 200, height: 100)
                ],
                label: "candidate-blocks-deeper-candidate"
            )
        }

        if allPassed {
            print("PlaceholderPassThroughPolicyTests: all tests passed")
        }
        return allPassed
    }
}
