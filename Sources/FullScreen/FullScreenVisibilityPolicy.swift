/// Pure decision logic for "should this window be tracked as full-screen on its display?"
///
/// A native full-screen window lives in its own dedicated Space, so the active-Space
/// on-screen list correctly excludes it whenever another Space is showing on its display.
/// CGS Spaces (`CGSCopySpacesForWindows` + `CGSSpaceGetType == kCGSSpaceFullscreen`)
/// resolves the ambiguity by reporting the window's Space membership directly.
///
/// Heuristic-only full-screen (`treatAsFullScreen` from the AXUnknown full-width rule) is
/// not a real Space, so it does not get the CGS Spaces tie-breaker.
import Foundation

enum FullScreenVisibilityPolicy {
    /// Decide whether the window should be considered "on-screen as full-screen" for tracker
    /// purposes, given the active-Space check and CGS Space membership.
    ///
    /// - Parameters:
    ///   - claimsFullScreen: AX `AXFullScreen == true` OR the heuristic fired.
    ///   - isNative: AX `AXFullScreen == true` (independent of the heuristic).
    ///   - isOnScreenInActiveSpace: Result of the WindowServer on-screen-only list check;
    ///     `nil` when the API call could not be evaluated.
    ///   - isInNativeFullScreenSpace: CGS Spaces reports the window in a `kCGSSpaceFullscreen` Space.
    /// - Returns: `true` when the tracker should treat the window as full-screen.
    static func shouldTrackAsFullScreen(
        claimsFullScreen: Bool,
        isNative: Bool,
        isOnScreenInActiveSpace: Bool?,
        isInNativeFullScreenSpace: Bool
    ) -> Bool {
        guard claimsFullScreen else { return false }
        // When the active-Space check is unavailable, stay conservative: trust AX/heuristic.
        guard let isOnScreenInActiveSpace else { return true }
        if isOnScreenInActiveSpace { return true }
        // Off-screen in the active Space — but native FS lives in its own Space. If CGS
        // confirms FS Space membership, the FS state is real and just inactive on this screen.
        if isNative && isInNativeFullScreenSpace { return true }
        return false
    }
}
