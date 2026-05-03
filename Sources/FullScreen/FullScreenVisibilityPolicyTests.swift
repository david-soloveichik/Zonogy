import Foundation

/// Lightweight runtime assertions for `FullScreenVisibilityPolicy`.
enum FullScreenVisibilityPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("FullScreenVisibilityPolicyTests: \(message)")
                allPassed = false
            }
        }

        // Not claimed → not tracked, regardless of other inputs.
        assert(
            FullScreenVisibilityPolicy.shouldTrackAsFullScreen(
                claimsFullScreen: false,
                isNative: false,
                isOnScreenInActiveSpace: true,
                isInNativeFullScreenSpace: true
            ) == false,
            "no claim → not tracked"
        )

        // Claimed + on-screen → tracked (the simple case).
        assert(
            FullScreenVisibilityPolicy.shouldTrackAsFullScreen(
                claimsFullScreen: true,
                isNative: true,
                isOnScreenInActiveSpace: true,
                isInNativeFullScreenSpace: true
            ) == true,
            "claimed + on-screen → tracked"
        )

        // Claimed + on-screen check unavailable (nil) → conservative trust → tracked.
        assert(
            FullScreenVisibilityPolicy.shouldTrackAsFullScreen(
                claimsFullScreen: true,
                isNative: true,
                isOnScreenInActiveSpace: nil,
                isInNativeFullScreenSpace: false
            ) == true,
            "claimed + on-screen unknown → conservatively tracked"
        )

        // Claimed + off-screen + native + CGS confirms FS Space → tracked.
        assert(
            FullScreenVisibilityPolicy.shouldTrackAsFullScreen(
                claimsFullScreen: true,
                isNative: true,
                isOnScreenInActiveSpace: false,
                isInNativeFullScreenSpace: true
            ) == true,
            "claimed native + off-screen but in FS Space → still tracked (inactive Space)"
        )

        // Claimed + off-screen + native + CGS says NOT in FS Space → not tracked.
        // (e.g., window destroyed or moved out of FS).
        assert(
            FullScreenVisibilityPolicy.shouldTrackAsFullScreen(
                claimsFullScreen: true,
                isNative: true,
                isOnScreenInActiveSpace: false,
                isInNativeFullScreenSpace: false
            ) == false,
            "native off-screen and not in FS Space → not tracked"
        )

        // Claimed + off-screen + heuristic-only (not native) → not tracked, even if CGS
        // happens to say FS Space. Heuristic FS doesn't get the CGS Spaces escape hatch.
        assert(
            FullScreenVisibilityPolicy.shouldTrackAsFullScreen(
                claimsFullScreen: true,
                isNative: false,
                isOnScreenInActiveSpace: false,
                isInNativeFullScreenSpace: true
            ) == false,
            "heuristic-only off-screen → not tracked even if CGS says FS Space"
        )

        if allPassed {
            print("FullScreenVisibilityPolicyTests: all tests passed")
        }
        return allPassed
    }
}
