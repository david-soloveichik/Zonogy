import CoreGraphics

/// Guardrail tests for the pure occupancy-change auto-save decision logic.
enum WinShotOccupancyAutoSavePlanTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotOccupancyAutoSavePlanTests: \(message)")
                allPassed = false
            }
        }

        func sig(
            tiled: [Int: Int],
            floating: Int? = nil,
            present: [Int]? = nil
        ) -> WinShotSnapshotOccupancySignature {
            WinShotSnapshotOccupancySignature(
                presentZoneIndices: present ?? Array(tiled.keys),
                tiledWindowIdsByZoneIndex: tiled,
                floatingZoneWindowId: floating
            )
        }

        let screenA: CGDirectDisplayID = 1
        let screenB: CGDirectDisplayID = 2

        // A newly tracked screen arms its timer.
        var decision = WinShotOccupancyAutoSavePlan.decide(
            previous: [:],
            current: [screenA: sig(tiled: [1: 10])]
        )
        assert(decision.screensToArm == [screenA], "new screen should arm")
        assert(decision.screensToCancel.isEmpty, "new screen should not cancel anything")

        // An unchanged signature does not re-arm (so a long-lived arrangement is captured once).
        let stable = sig(tiled: [1: 10])
        decision = WinShotOccupancyAutoSavePlan.decide(
            previous: [screenA: stable],
            current: [screenA: stable]
        )
        assert(decision.screensToArm.isEmpty, "unchanged signature should not arm")
        assert(decision.screensToCancel.isEmpty, "unchanged signature should not cancel")

        // A changed occupant re-arms.
        decision = WinShotOccupancyAutoSavePlan.decide(
            previous: [screenA: sig(tiled: [1: 10])],
            current: [screenA: sig(tiled: [1: 11])]
        )
        assert(decision.screensToArm == [screenA], "changed occupant should arm")

        // Floating-zone occupant change re-arms.
        decision = WinShotOccupancyAutoSavePlan.decide(
            previous: [screenA: sig(tiled: [1: 10], floating: nil)],
            current: [screenA: sig(tiled: [1: 10], floating: 99)]
        )
        assert(decision.screensToArm == [screenA], "floating occupant change should arm")

        // Adding a zone (present indices differ) re-arms — zone add/remove counts as occupancy change.
        decision = WinShotOccupancyAutoSavePlan.decide(
            previous: [screenA: sig(tiled: [1: 10], present: [1])],
            current: [screenA: sig(tiled: [1: 10], present: [1, 2])]
        )
        assert(decision.screensToArm == [screenA], "adding an (empty) zone should arm")

        // A screen that disappears is cancelled, not armed.
        decision = WinShotOccupancyAutoSavePlan.decide(
            previous: [screenA: sig(tiled: [1: 10])],
            current: [:]
        )
        assert(decision.screensToCancel == [screenA], "removed screen should cancel")
        assert(decision.screensToArm.isEmpty, "removed screen should not arm")

        // Multiple screens: only the changed one arms; an unchanged one is left alone.
        decision = WinShotOccupancyAutoSavePlan.decide(
            previous: [screenA: sig(tiled: [1: 10]), screenB: sig(tiled: [1: 20])],
            current: [screenA: sig(tiled: [1: 10]), screenB: sig(tiled: [1: 21])]
        )
        assert(decision.screensToArm == [screenB], "only the changed screen should arm")
        assert(decision.screensToCancel.isEmpty, "no screen should cancel")

        if allPassed {
            print("WinShotOccupancyAutoSavePlanTests: all tests passed")
        }
        return allPassed
    }
}
