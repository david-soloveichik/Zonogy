import AppKit

/// Guardrail tests for WinShot chooser window sizing from gap-spaced content.
enum WinShotChooserViewTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotChooserViewTests: \(message)")
                allPassed = false
            }
        }

        func snapshot(createdAt: Date) -> WinShotSnapshot {
            WinShotSnapshot(
                id: UUID(),
                screenId: 0,
                createdAt: createdAt,
                zoneCount: 1,
                zoneFrames: [:],
                windowFrames: [:],
                rememberedTiledWindowSizesByZoneIndex: [:],
                zoneAssignments: [:],
                floatingZoneOccupant: nil,
                floatingZoneFrame: nil,
                activeWindowId: nil,
                thumbnail: nil
            )
        }

        let base = Date(timeIntervalSinceReferenceDate: 100_000)

        do {
            // A single snapshot still respects the minimum window width.
            let size = WinShotChooserView.preferredWindowSize(
                for: [snapshot(createdAt: base)],
                screenVisibleWidth: 1600
            )
            assert(size.width >= 300, "preferred width should respect minimum window width")
        }

        do {
            // Adaptive scaling: a set whose intervals genuinely vary fills the visual range
            // (wider window); a set of near-equal intervals stays tight. Absolute magnitude
            // does not matter — only the spread of intervals within the set does.
            let varied = [
                snapshot(createdAt: base),
                snapshot(createdAt: base.addingTimeInterval(-10)),
                snapshot(createdAt: base.addingTimeInterval(-1_010)),
            ]
            let uniform = [
                snapshot(createdAt: base),
                snapshot(createdAt: base.addingTimeInterval(-40)),
                snapshot(createdAt: base.addingTimeInterval(-80)),
            ]
            let variedSize = WinShotChooserView.preferredWindowSize(for: varied, screenVisibleWidth: 6000)
            let uniformSize = WinShotChooserView.preferredWindowSize(for: uniform, screenVisibleWidth: 6000)
            assert(variedSize.width > uniformSize.width, "more interval spread should widen the window")
        }

        do {
            // Window width is capped to a fraction of the screen (content scrolls beyond).
            let many = (0..<20).map { snapshot(createdAt: base.addingTimeInterval(Double(-$0) * 86_400)) }
            let narrow = WinShotChooserView.preferredWindowSize(for: many, screenVisibleWidth: 1280)
            let wide = WinShotChooserView.preferredWindowSize(for: many, screenVisibleWidth: 1920)
            assert(narrow.width <= 1280 * 0.9 + 0.5, "window should not exceed the screen-width cap")
            assert(wide.width > narrow.width, "wider screens should allow a wider window")
        }

        if allPassed {
            print("WinShotChooserViewTests: all tests passed")
        }
        return allPassed
    }
}
