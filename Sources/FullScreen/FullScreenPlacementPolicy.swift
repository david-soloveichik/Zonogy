/// Pure decision logic for placing a newly opened or unminimized window relative to
/// full-screen pause state. Tested via `FullScreenPlacementPolicyTests`.
///
/// Both full-screen kinds route arrivals to an available display, or defer when none exists.
/// Only native full screen needs its original Space restored after placement.
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
        guard !targetIsPausedForFullScreen else {
            return .defer
        }
        guard let originScreenId, originIsPausedForFullScreen else {
            return .proceedNormally
        }
        guard let targetedScreenId, targetedScreenId != originScreenId else {
            return .defer
        }
        return originIsNativeFullScreen
            ? .placeAndRestoreNativeFullScreenSpace(originScreenId: originScreenId)
            : .proceedNormally
    }
}
