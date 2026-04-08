import Foundation

/// Guardrail tests for the has-main-window secondary-window floating exception.
enum MainWindowSecondaryFloatingPlacementPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("MainWindowSecondaryFloatingPlacementPolicyTests: \(message)")
                allPassed = false
            }
        }

        let windows = [
            MainWindowSecondaryFloatingPlacementPolicy.CandidateWindow(windowId: 10, cgWindowId: 100),
            MainWindowSecondaryFloatingPlacementPolicy.CandidateWindow(windowId: 11, cgWindowId: 101),
            MainWindowSecondaryFloatingPlacementPolicy.CandidateWindow(windowId: 12, cgWindowId: 102),
        ]

        do {
            let result = MainWindowSecondaryFloatingPlacementPolicy.shouldRedirectToFloating(
                hasMainWindow: true,
                floatsSecondaryWindowsWhenMainWindowIsTargeted: true,
                incomingWindowId: 11,
                targetedZoneOccupantWindowId: 10,
                sameAppWindows: windows
            )
            assert(result, "secondary window should redirect when the targeted occupant is the app's main window")
        }

        do {
            let result = MainWindowSecondaryFloatingPlacementPolicy.shouldRedirectToFloating(
                hasMainWindow: false,
                floatsSecondaryWindowsWhenMainWindowIsTargeted: true,
                incomingWindowId: 11,
                targetedZoneOccupantWindowId: 10,
                sameAppWindows: windows
            )
            assert(!result, "redirect should require hasMainWindow")
        }

        do {
            let result = MainWindowSecondaryFloatingPlacementPolicy.shouldRedirectToFloating(
                hasMainWindow: true,
                floatsSecondaryWindowsWhenMainWindowIsTargeted: false,
                incomingWindowId: 11,
                targetedZoneOccupantWindowId: 10,
                sameAppWindows: windows
            )
            assert(!result, "redirect should require the secondary-window floating suboption")
        }

        do {
            let result = MainWindowSecondaryFloatingPlacementPolicy.shouldRedirectToFloating(
                hasMainWindow: true,
                floatsSecondaryWindowsWhenMainWindowIsTargeted: true,
                incomingWindowId: 11,
                targetedZoneOccupantWindowId: 12,
                sameAppWindows: windows
            )
            assert(!result, "redirect should not occur when the targeted occupant is not the app's main window")
        }

        do {
            let result = MainWindowSecondaryFloatingPlacementPolicy.shouldRedirectToFloating(
                hasMainWindow: true,
                floatsSecondaryWindowsWhenMainWindowIsTargeted: true,
                incomingWindowId: 10,
                targetedZoneOccupantWindowId: 10,
                sameAppWindows: windows
            )
            assert(!result, "the main window itself should not redirect to floating")
        }

        do {
            let result = MainWindowSecondaryFloatingPlacementPolicy.shouldRedirectToFloating(
                hasMainWindow: true,
                floatsSecondaryWindowsWhenMainWindowIsTargeted: true,
                incomingWindowId: 99,
                targetedZoneOccupantWindowId: 10,
                sameAppWindows: windows
            )
            assert(!result, "redirect should require the incoming window to be part of the same-app window set")
        }

        if allPassed {
            print("MainWindowSecondaryFloatingPlacementPolicyTests: all tests passed")
        }
        return allPassed
    }
}
