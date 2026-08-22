import CoreGraphics
import Foundation

/// Guardrail tests for mapping a WinShot snapshot onto another display's visible bounds.
enum WinShotSnapshotRetargetingTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotSnapshotRetargetingTests: \(message)")
                allPassed = false
            }
        }

        func identity(_ windowId: Int) -> WindowIdentity {
            WindowIdentity(
                windowId: windowId,
                externalIdentifier: ExternalWindowIdentifier(pid: pid_t(windowId), cgWindowId: windowId),
                bundleIdentifier: "com.example.\(windowId)",
                windowTitle: "Window \(windowId)"
            )
        }

        // Captured on 1000x500 visible bounds that start below a 25pt menu bar.
        let source = CGRect(x: 0, y: 25, width: 1000, height: 500)
        let floatingFrame = CGRect(x: 100, y: 125, width: 400, height: 300)
        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let snapshot = WinShotSnapshot(
            id: UUID(),
            screenId: 1,
            createdAt: createdAt,
            lastActiveAt: createdAt,
            layoutBounds: source,
            zoneCount: 2,
            zoneFrames: [
                1: CGRect(x: 0, y: 25, width: 600, height: 500),
                2: CGRect(x: 600, y: 25, width: 400, height: 500),
            ],
            rememberedTiledWindowSizesByZoneIndex: [1: CGSize(width: 700, height: 400)],
            zoneAssignments: [1: identity(101)],
            floatingZoneOccupant: identity(202),
            floatingZoneFrame: floatingFrame,
            activeWindowId: 202,
            thumbnail: nil
        )

        do {
            // Twice as wide, same height, no menu-bar inset: the tiling arrangement scales with it.
            let destination = CGRect(x: 0, y: 0, width: 2000, height: 500)
            let retargeted = snapshot.retargeted(to: 2, layoutBounds: destination)
            assert(retargeted.screenId == 2, "retargeted snapshot should carry the destination display")
            assert(retargeted.layoutBounds == destination, "retargeted snapshot should record the destination area")
            assert(retargeted.id == snapshot.id && retargeted.activeWindowId == 202, "identity and active window should carry over")
            assert(
                retargeted.zoneFrames[1] == CGRect(x: 0, y: 0, width: 1200, height: 500)
                    && retargeted.zoneFrames[2] == CGRect(x: 1200, y: 0, width: 800, height: 500),
                "zone frames should scale proportionally into the destination area"
            )
            assert(
                retargeted.rememberedTiledWindowSizesByZoneIndex[1] == CGSize(width: 1400, height: 400),
                "Sticky Resize remembered sizes should scale with their zones"
            )
            // Floating window: same size, center kept at the same relative position.
            // Source center (300, 275) sits at (0.3, 0.5) of the area; destination center is (600, 250).
            assert(
                retargeted.floatingZoneFrame == CGRect(x: 400, y: 100, width: 400, height: 300),
                "floating window should keep its size at the same relative position, got \(String(describing: retargeted.floatingZoneFrame))"
            )
        }

        do {
            // A smaller destination: the floating window keeps its size but is nudged fully on-screen.
            let destination = CGRect(x: 0, y: 0, width: 500, height: 400)
            let retargeted = snapshot.retargeted(to: 2, layoutBounds: destination)
            // Relative center (0.3, 0.5) -> (150, 200); a 400x300 window centered there would start at
            // x = -50, so it is nudged to the left edge.
            assert(
                retargeted.floatingZoneFrame == CGRect(x: 0, y: 50, width: 400, height: 300),
                "floating window should be nudged to stay within the destination area, got \(String(describing: retargeted.floatingZoneFrame))"
            )
        }

        do {
            // A destination smaller than the floating window: only then is the window shrunk to fit.
            let destination = CGRect(x: 0, y: 0, width: 300, height: 200)
            let retargeted = snapshot.retargeted(to: 2, layoutBounds: destination)
            assert(
                retargeted.floatingZoneFrame == CGRect(x: 0, y: 0, width: 300, height: 200),
                "floating window larger than the destination area should shrink to fit, got \(String(describing: retargeted.floatingZoneFrame))"
            )
        }

        do {
            // Same visible area: every frame is reproduced exactly, including a floating window that
            // sat partly off-screen.
            let offscreen = WinShotSnapshot(
                id: snapshot.id,
                screenId: 1,
                createdAt: createdAt,
                lastActiveAt: createdAt,
                layoutBounds: source,
                zoneCount: 1,
                zoneFrames: [1: source],
                rememberedTiledWindowSizesByZoneIndex: [:],
                zoneAssignments: [:],
                floatingZoneOccupant: identity(202),
                floatingZoneFrame: CGRect(x: 800, y: 400, width: 400, height: 300),
                activeWindowId: nil,
                thumbnail: nil
            )
            let retargeted = offscreen.retargeted(to: 1, layoutBounds: source)
            assert(
                retargeted.floatingZoneFrame == offscreen.floatingZoneFrame && retargeted.zoneFrames == offscreen.zoneFrames,
                "identical visible areas should leave frames untouched"
            )
        }

        if allPassed {
            print("WinShotSnapshotRetargetingTests: all tests passed")
        }
        return allPassed
    }
}
