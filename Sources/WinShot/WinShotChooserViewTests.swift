import AppKit

/// Guardrail tests for WinShot chooser width-based tile visibility.
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

        do {
            let narrow = WinShotChooserView.visibleTileCount(
                for: 20,
                screenVisibleWidth: 1280,
                maxSnapshotsStored: 20
            )
            let wide = WinShotChooserView.visibleTileCount(
                for: 20,
                screenVisibleWidth: 1920,
                maxSnapshotsStored: 20
            )
            assert(wide > narrow, "wider screens should show more tiles")
        }

        do {
            let count = WinShotChooserView.visibleTileCount(
                for: 20,
                screenVisibleWidth: 3000,
                maxSnapshotsStored: 4
            )
            assert(count == 4, "tile count should never exceed max snapshots setting")
        }

        do {
            let count = WinShotChooserView.visibleTileCount(
                for: 3,
                screenVisibleWidth: 3000,
                maxSnapshotsStored: 20
            )
            assert(count == 3, "tile count should never exceed available snapshots")
        }

        do {
            let count = WinShotChooserView.visibleTileCount(
                for: 10,
                screenVisibleWidth: 0,
                maxSnapshotsStored: 20
            )
            assert(count == 5, "unknown screen width should use fallback visible tile count")
        }

        do {
            let size = WinShotChooserView.preferredWindowSize(
                for: 10,
                screenVisibleWidth: 1600,
                maxSnapshotsStored: 20
            )
            assert(size.width >= 300, "preferred width should respect minimum window width")
        }

        if allPassed {
            print("WinShotChooserViewTests: all tests passed")
        }
        return allPassed
    }
}
