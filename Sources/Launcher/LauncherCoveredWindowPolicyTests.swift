import Foundation
import CoreGraphics

/// Simple assertions for LauncherCoveredWindowPolicy behavior.
enum LauncherCoveredWindowPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func expect(_ actual: Set<Int>, _ expected: Set<Int>, _ label: String) {
            if actual != expected {
                print("LauncherCoveredWindowPolicyTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
            }
        }

        let zonogyPid: pid_t = 100
        func row(_ windowNumber: Int, _ frame: CGRect, pid: pid_t = 200, layer: Int = 0) -> WindowServerWindowRow {
            WindowServerWindowRow(windowNumber: windowNumber, ownerPid: pid, layer: layer, alpha: 1, frame: frame)
        }

        // Two zones side by side; the Launcher sits on the right zone and overhangs into the left.
        let leftZone = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let rightZone = CGRect(x: 500, y: 0, width: 500, height: 1000)
        let launcher = CGRect(x: 450, y: 300, width: 450, height: 400)

        let under = row(10, CGRect(x: 600, y: 400, width: 300, height: 300))
        let outsideLauncher = row(11, CGRect(x: 520, y: 800, width: 200, height: 150))
        let inLeftOverhang = row(12, CGRect(x: 300, y: 400, width: 180, height: 200))
        let placeholder = row(13, rightZone, pid: zonogyPid)
        let floatingPanel = row(14, CGRect(x: 600, y: 400, width: 300, height: 300), layer: 3)
        let sliver = row(15, CGRect(x: 899.5, y: 100, width: 300, height: 400))

        func covered(_ rows: [WindowServerWindowRow], zones: [CGRect] = [leftZone, rightZone], managed: Set<Int> = []) -> Set<Int> {
            LauncherCoveredWindowPolicy.coveredUnmanagedWindowNumbers(
                launcherFrame: launcher,
                zoneFrames: zones,
                rows: rows,
                zonogyPid: zonogyPid,
                managedWindowNumbers: managed
            )
        }

        // Z-order is irrelevant: a window in front of the placeholder counts like one behind it.
        expect(covered([under, placeholder]), [10], "window-in-front-counts")
        expect(covered([placeholder, under]), [10], "window-behind-counts")

        // Only windows actually under the Launcher count; Zonogy's own windows, non-normal
        // layers, and shadow-tolerance slivers are ignored like the pass-through policy does.
        expect(covered([under, outsideLauncher, placeholder, floatingPanel, sliver]), [10], "outside-and-excluded-rows")

        // Managed windows never count.
        expect(covered([under], managed: [10]), [], "managed-ignored")

        // Overhang into a neighboring zone counts only when that zone is among the frames.
        expect(covered([inLeftOverhang]), [12], "overhang-into-empty-zone")
        expect(covered([inLeftOverhang], zones: [rightZone]), [], "overhang-into-occupied-zone-ignored")

        expect(covered([]), [], "no-windows")

        // Placement / yield decisions.
        typealias Placement = LauncherCoveredWindowPolicy.Placement
        func decide(_ placement: Placement?, at frame: CGRect, covered: Set<Int>) -> LauncherCoveredWindowPolicy.YieldDecision {
            LauncherCoveredWindowPolicy.yieldDecision(placement: placement, launcherFrame: frame, coveredWindowNumbers: covered)
        }
        let moved = launcher.offsetBy(dx: 0, dy: 200)
        let placed = Placement(frame: launcher, toleratedWindowNumbers: [10])
        func expectDecision(_ actual: LauncherCoveredWindowPolicy.YieldDecision, _ expected: LauncherCoveredWindowPolicy.YieldDecision, _ label: String) {
            if actual != expected {
                print("LauncherCoveredWindowPolicyTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
            }
        }
        // First reading establishes the placement, tolerating whatever is beneath.
        expectDecision(decide(nil, at: launcher, covered: [10]), .keep(placed), "first-reading-tolerates")
        // Same place, same or fewer windows: keep as is.
        expectDecision(decide(placed, at: launcher, covered: [10]), .keep(placed), "unchanged-keeps")
        expectDecision(decide(placed, at: launcher, covered: []), .keep(placed), "vanished-keeps")
        // Same place, a newcomer: yield — also when nothing was tolerated, or the tolerated
        // window was replaced by another.
        expectDecision(decide(placed, at: launcher, covered: [10, 11]), .yield, "newcomer-yields")
        expectDecision(
            decide(Placement(frame: launcher, toleratedWindowNumbers: []), at: launcher, covered: [11]),
            .yield,
            "first-arrival-yields"
        )
        expectDecision(decide(placed, at: launcher, covered: [11]), .yield, "replacement-yields")
        // Moved since the placement: the new location's windows are tolerated, newcomer or not.
        expectDecision(
            decide(placed, at: moved, covered: [11]),
            .keep(Placement(frame: moved, toleratedWindowNumbers: [11])),
            "moved-re-places"
        )

        if allPassed {
            print("LauncherCoveredWindowPolicyTests: all tests passed")
        }
        return allPassed
    }
}
