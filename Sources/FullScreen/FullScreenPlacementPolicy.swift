/// Pure decision logic for placing a newly opened or unminimized window relative to
/// full-screen pause state. Tested via `FullScreenPlacementPolicyTests`.
///
/// Inputs are the screens involved (origin and target) and their pause/native flags.
/// Output classifies the placement into one of three actions:
/// - `.proceedNormally` — origin is not paused; defer/proceed is decided elsewhere (e.g. drag tear-out).
/// - `.defer` — origin is paused for full-screen and we should park the window per the standard rule.
/// - `.placeAndRestoreNativeFullScreenSpace` — origin is paused for *native* full-screen and the
///   targeted destination lives on a different non-paused screen. Place via the standard pipeline,
///   then re-raise the origin's full-screen window so macOS switches that screen back to its
///   full-screen Space.
import Foundation
import CoreGraphics

enum FullScreenPlacementOutcome: Equatable {
    case proceedNormally
    case `defer`
    case placeAndRestoreNativeFullScreenSpace(originScreenId: CGDirectDisplayID)
}

enum FullScreenPlacementPolicy {
    static func decide(
        originScreenId: CGDirectDisplayID?,
        originIsPausedForFullScreen: Bool,
        originIsNativeFullScreen: Bool,
        targetedScreenId: CGDirectDisplayID?,
        targetIsPausedForFullScreen: Bool
    ) -> FullScreenPlacementOutcome {
        guard let originScreenId, originIsPausedForFullScreen else {
            return .proceedNormally
        }
        if originIsNativeFullScreen,
           let targetedScreenId,
           targetedScreenId != originScreenId,
           !targetIsPausedForFullScreen {
            return .placeAndRestoreNativeFullScreenSpace(originScreenId: originScreenId)
        }
        return .defer
    }
}
