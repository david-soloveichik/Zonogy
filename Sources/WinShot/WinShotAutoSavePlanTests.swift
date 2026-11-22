import CoreGraphics

/// Guardrail tests for the pure WinShot auto-save decision logic.
enum WinShotAutoSavePlanTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotAutoSavePlanTests: \(message)")
                allPassed = false
            }
        }

        func state(
            tiled: [Int: Int],
            floating: Int? = nil,
            present: [Int]? = nil,
            zoneFrames: [CGRect] = [],
            floatingFrame: CGRect? = nil,
            stickySizes: [Int: CGSize] = [:]
        ) -> WinShotArrangementState {
            WinShotArrangementState(
                occupancy: WinShotSnapshotOccupancySignature(
                    presentZoneIndices: present ?? tiled.keys.sorted(),
                    tiledWindowIdsByZoneIndex: tiled,
                    floatingZoneWindowId: floating
                ),
                zoneFrames: zoneFrames,
                floatingWindowFrame: floatingFrame,
                stickyResizeSizes: stickySizes
            )
        }

        let screenA: CGDirectDisplayID = 1
        let screenB: CGDirectDisplayID = 2

        // A newly tracked screen arms its timer.
        var decision = WinShotAutoSavePlan.decide(
            previous: [:],
            current: [screenA: state(tiled: [1: 10])]
        )
        assert(decision.screensToArm == [screenA], "new screen should arm")
        assert(decision.screensToCancel.isEmpty, "new screen should not cancel anything")

        // An unchanged arrangement does not re-arm (so a long-lived arrangement is captured once).
        let stable = state(tiled: [1: 10])
        decision = WinShotAutoSavePlan.decide(
            previous: [screenA: stable],
            current: [screenA: stable]
        )
        assert(decision.screensToArm.isEmpty, "unchanged arrangement should not arm")
        assert(decision.screensToCancel.isEmpty, "unchanged arrangement should not cancel")

        // A changed occupant re-arms.
        decision = WinShotAutoSavePlan.decide(
            previous: [screenA: state(tiled: [1: 10])],
            current: [screenA: state(tiled: [1: 11])]
        )
        assert(decision.screensToArm == [screenA], "changed occupant should arm")

        // Floating-zone occupant change re-arms.
        decision = WinShotAutoSavePlan.decide(
            previous: [screenA: state(tiled: [1: 10], floating: nil)],
            current: [screenA: state(tiled: [1: 10], floating: 99)]
        )
        assert(decision.screensToArm == [screenA], "floating occupant change should arm")

        // Adding a zone (present indices differ) re-arms, even an empty one.
        decision = WinShotAutoSavePlan.decide(
            previous: [screenA: state(tiled: [1: 10], present: [1])],
            current: [screenA: state(tiled: [1: 10], present: [1, 2])]
        )
        assert(decision.screensToArm == [screenA], "adding an (empty) zone should arm")

        // Geometry alone is a change: resizing a zone, moving the floating window, or a Sticky
        // Resize each re-arm.
        let zoneFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let floatingFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let base = state(tiled: [1: 10], floating: 99, zoneFrames: [zoneFrame], floatingFrame: floatingFrame)
        let geometryChanges: [(WinShotArrangementState, String)] = [
            (state(tiled: [1: 10], floating: 99, zoneFrames: [zoneFrame.insetBy(dx: 50, dy: 0)],
                   floatingFrame: floatingFrame), "zone resize"),
            (state(tiled: [1: 10], floating: 99, zoneFrames: [zoneFrame],
                   floatingFrame: floatingFrame.offsetBy(dx: 20, dy: 0)), "floating window move"),
            (state(tiled: [1: 10], floating: 99, zoneFrames: [zoneFrame], floatingFrame: floatingFrame,
                   stickySizes: [10: CGSize(width: 500, height: 400)]), "Sticky Resize"),
        ]
        for (changed, label) in geometryChanges {
            decision = WinShotAutoSavePlan.decide(previous: [screenA: base], current: [screenA: changed])
            assert(decision.screensToArm == [screenA], "\(label) should arm")
        }

        // A screen that disappears is cancelled, not armed.
        decision = WinShotAutoSavePlan.decide(
            previous: [screenA: state(tiled: [1: 10])],
            current: [:]
        )
        assert(decision.screensToCancel == [screenA], "removed screen should cancel")
        assert(decision.screensToArm.isEmpty, "removed screen should not arm")

        // Multiple screens: only the changed one arms; an unchanged one is left alone.
        decision = WinShotAutoSavePlan.decide(
            previous: [screenA: state(tiled: [1: 10]), screenB: state(tiled: [1: 20])],
            current: [screenA: state(tiled: [1: 10]), screenB: state(tiled: [1: 21])]
        )
        assert(decision.screensToArm == [screenB], "only the changed screen should arm")
        assert(decision.screensToCancel.isEmpty, "no screen should cancel")

        if allPassed {
            print("WinShotAutoSavePlanTests: all tests passed")
        }
        return allPassed
    }
}
