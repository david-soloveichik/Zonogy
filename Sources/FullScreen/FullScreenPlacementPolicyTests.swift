import Foundation
import CoreGraphics

/// Lightweight runtime assertions for the partial-pause placement decision rules.
enum FullScreenPlacementPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("FullScreenPlacementPolicyTests: \(message)")
                allPassed = false
            }
        }

        let screenA: CGDirectDisplayID = 1
        let screenB: CGDirectDisplayID = 2

        // Origin not paused → proceed (defer-or-not is decided elsewhere).
        assert(
            FullScreenPlacementPolicy.decide(
                originScreenId: screenA,
                originIsPausedForFullScreen: false,
                originIsNativeFullScreen: false,
                targetedScreenId: screenB,
                targetIsPausedForFullScreen: false
            ) == .proceedNormally,
            "non-paused origin should proceed normally"
        )

        // Origin missing (unknown screen) → proceed normally.
        assert(
            FullScreenPlacementPolicy.decide(
                originScreenId: nil,
                originIsPausedForFullScreen: true,
                originIsNativeFullScreen: true,
                targetedScreenId: screenB,
                targetIsPausedForFullScreen: false
            ) == .proceedNormally,
            "missing origin screen should proceed normally"
        )

        // Origin paused but heuristic-only (not native) → defer (today's behavior preserved).
        assert(
            FullScreenPlacementPolicy.decide(
                originScreenId: screenA,
                originIsPausedForFullScreen: true,
                originIsNativeFullScreen: false,
                targetedScreenId: screenB,
                targetIsPausedForFullScreen: false
            ) == .defer,
            "heuristic full-screen pause should still defer"
        )

        // Origin paused, native, target nil → defer.
        assert(
            FullScreenPlacementPolicy.decide(
                originScreenId: screenA,
                originIsPausedForFullScreen: true,
                originIsNativeFullScreen: true,
                targetedScreenId: nil,
                targetIsPausedForFullScreen: false
            ) == .defer,
            "native FS pause with no target should defer"
        )

        // Origin paused, native, target on the same paused screen → defer (must be different screen).
        assert(
            FullScreenPlacementPolicy.decide(
                originScreenId: screenA,
                originIsPausedForFullScreen: true,
                originIsNativeFullScreen: true,
                targetedScreenId: screenA,
                targetIsPausedForFullScreen: true
            ) == .defer,
            "native FS pause with target on same paused screen should defer"
        )

        // Origin paused, native, target on a different but also-paused screen (all-FS fallback) → defer.
        assert(
            FullScreenPlacementPolicy.decide(
                originScreenId: screenA,
                originIsPausedForFullScreen: true,
                originIsNativeFullScreen: true,
                targetedScreenId: screenB,
                targetIsPausedForFullScreen: true
            ) == .defer,
            "all-FS fallback (target also paused) should defer"
        )

        // Origin paused, native, target on a different non-paused screen → partial pause.
        assert(
            FullScreenPlacementPolicy.decide(
                originScreenId: screenA,
                originIsPausedForFullScreen: true,
                originIsNativeFullScreen: true,
                targetedScreenId: screenB,
                targetIsPausedForFullScreen: false
            ) == .placeAndRestoreNativeFullScreenSpace(originScreenId: screenA),
            "native FS pause with non-paused target should place + restore"
        )

        if allPassed {
            print("FullScreenPlacementPolicyTests: all tests passed")
        }
        return allPassed
    }
}
