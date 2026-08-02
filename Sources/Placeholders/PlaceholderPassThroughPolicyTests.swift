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

        // Window behind the placeholder → hole over the overlap. Managed and unmanaged windows
        // punch alike; the window server routes clicks to whichever window is topmost there.
        do {
            let behind = row(2, CGRect(x: 300, y: 300, width: 400, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, behind],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [CGRect(x: 300, y: 300, width: 200, height: 200)], label: "behind-overlapping")
        }

        // Same window in front of the placeholder → no hole.
        do {
            let inFront = row(2, CGRect(x: 300, y: 300, width: 400, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [inFront, placeholder],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [], label: "in-front-no-hole")
        }

        // Zonogy's own window behind (another placeholder/overlay) → no hole.
        do {
            let ownWindow = row(2, CGRect(x: 300, y: 300, width: 400, height: 300), pid: zonogyPid)
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, ownWindow],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [], label: "own-pid-excluded")
        }

        // Non-normal-level window behind (e.g. a floating panel dipping under) → no hole.
        do {
            let floating = row(2, CGRect(x: 300, y: 300, width: 400, height: 300), layer: 3)
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, floating],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [], label: "non-normal-layer-excluded")
        }

        // Fully transparent window behind → no hole (clicks already pass through it).
        do {
            let invisible = row(2, CGRect(x: 300, y: 300, width: 400, height: 300), alpha: 0)
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, invisible],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [], label: "zero-alpha-excluded")
        }

        // Sliver overlap within the shadow-tolerance inset → no hole.
        do {
            let sliver = row(2, CGRect(x: 495, y: 100, width: 300, height: 400))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, sliver],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [], label: "sliver-overlap-ignored")
        }

        // Behind but not overlapping → no hole.
        do {
            let elsewhere = row(2, CGRect(x: 600, y: 100, width: 300, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, elsewhere],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [], label: "no-overlap-no-hole")
        }

        // Tiny window (smaller than the inset tolerance, e.g. a 1x1 focus proxy) → no hole.
        do {
            let tiny = row(2, CGRect(x: 200, y: 200, width: 8, height: 8))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, tiny],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [], label: "tiny-window-ignored")
        }

        // Two disjoint qualifying windows behind → two holes, in z-order (front first).
        do {
            let first = row(2, CGRect(x: 150, y: 150, width: 100, height: 100))
            let second = row(3, CGRect(x: 350, y: 350, width: 300, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, first, second],
                zonogyPid: zonogyPid
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

        // Overlapping windows each punch their full overlap; the regions simply overlap
        // (the content view unions them into one path).
        do {
            let near = row(2, CGRect(x: 150, y: 150, width: 100, height: 100))
            let deep = row(3, CGRect(x: 150, y: 150, width: 300, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, near, deep],
                zonogyPid: zonogyPid
            )
            assertEqual(
                holes,
                [
                    CGRect(x: 150, y: 150, width: 100, height: 100),
                    CGRect(x: 150, y: 150, width: 300, height: 300)
                ],
                label: "overlapping-windows-overlapping-holes"
            )
        }

        // An excluded row (here: a sliver) above a deeper qualifying window does not clip the
        // deeper window's hole. Clicks over the sliver reach the sliver window (topmost there),
        // which is consistent with delegating routing to the window server.
        do {
            let sliver = row(2, CGRect(x: 495, y: 100, width: 300, height: 400))
            let deep = row(3, CGRect(x: 300, y: 100, width: 400, height: 400))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, sliver, deep],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [CGRect(x: 300, y: 100, width: 200, height: 400)], label: "excluded-row-above-deeper-candidate")
        }

        // Window fully covering the placeholder → hole equals the whole placeholder frame.
        do {
            let covering = row(2, CGRect(x: 0, y: 0, width: 1000, height: 1000))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [placeholder, covering],
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [placeholderFrame], label: "full-cover-full-hole")
        }

        // Placeholder missing from the z-order snapshot → no holes.
        do {
            let behind = row(2, CGRect(x: 300, y: 300, width: 400, height: 300))
            let holes = PlaceholderPassThroughPolicy.holeRects(
                placeholderCgWindowId: 1,
                rowsFrontToBack: [behind],
                zonogyPid: zonogyPid
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
                zonogyPid: zonogyPid
            )
            assertEqual(holes, [CGRect(x: 300, y: 300, width: 200, height: 200)], label: "mixed-stack")
        }

        if allPassed {
            print("PlaceholderPassThroughPolicyTests: all tests passed")
        }
        return allPassed
    }
}
