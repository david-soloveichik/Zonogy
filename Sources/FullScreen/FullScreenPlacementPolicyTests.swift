import Foundation
import CoreGraphics

/// Guardrails for routing arrivals, all-full-screen deferral, and native Space restoration.
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

        // A non-native presentation leaves the other display available for arrivals.
        assert(
            FullScreenPlacementPolicy.decide(
                originScreenId: screenA,
                originIsPausedForFullScreen: true,
                originIsNativeFullScreen: false,
                targetedScreenId: screenB,
                targetIsPausedForFullScreen: false
            ) == .proceedNormally,
            "non-native full-screen should route to an available display without a Space restore"
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

        // The unavailable target rule is independent of full-screen kind and display order.
        // A non-native target still has a regular Space, but remains paused for placement.
        for (origin, target) in [(screenA, screenB), (screenB, screenA)] {
            for native in [false, true] {
                assert(
                    FullScreenPlacementPolicy.decide(
                        originScreenId: origin,
                        originIsPausedForFullScreen: true,
                        originIsNativeFullScreen: native,
                        targetedScreenId: target,
                        targetIsPausedForFullScreen: true
                    ) == .defer,
                    "all-full-screen arrivals must defer for either origin kind and display order"
                )

                // Retrying the same arrival after either destination becomes available works
                // without requiring the originating display to leave full screen.
                let expected: FullScreenPlacementOutcome = native
                    ? .placeAndRestoreNativeFullScreenSpace(originScreenId: origin)
                    : .proceedNormally
                assert(
                    FullScreenPlacementPolicy.decide(
                        originScreenId: origin,
                        originIsPausedForFullScreen: true,
                        originIsNativeFullScreen: native,
                        targetedScreenId: target,
                        targetIsPausedForFullScreen: false
                    ) == expected,
                    "deferred arrivals should resume on an available destination"
                )
            }
        }

        // Native exit can clear the tracker before its Space switch ends. Destination
        // unavailability must win even when the origin appears regular or is unknown.
        for origin: CGDirectDisplayID? in [screenA, nil] {
            assert(
                FullScreenPlacementPolicy.decide(
                    originScreenId: origin,
                    originIsPausedForFullScreen: false,
                    originIsNativeFullScreen: false,
                    targetedScreenId: screenA,
                    targetIsPausedForFullScreen: true
                ) == .defer,
                "an unavailable destination must defer even without a paused origin"
            )
        }

        if allPassed {
            print("FullScreenPlacementPolicyTests: all tests passed")
        }
        return allPassed
    }
}
