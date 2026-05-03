/// Private CGS Spaces bridge for inspecting macOS full-screen Space membership.
///
/// `AXFullScreen` is Zonogy's native macOS full-screen signal: when it is true, we
/// classify the window as the green-button variety that lives in a dedicated full-screen
/// Space. Heuristic full-screen is separate and only applies when AX does not report
/// native full-screen.
///
/// CGS Spaces is needed for a different question: if a recorded native full-screen window
/// drops out of the WindowServer's active-Space on-screen list, did it exit full-screen,
/// or is its full-screen Space merely inactive because another Space is showing on that
/// display? `CGSCopySpacesForWindows` plus `CGSSpaceGetType == kCGSSpaceFullscreen` is
/// our best available tie-breaker for confirming Space membership.
///
/// The membership signal is load-bearing in two places — the tracker's on-screen filter
/// and the focused-window repair heuristic — where it disambiguates AX/active-Space
/// disagreement. Other callers use it defensively to confirm tracker state. See the
/// "CGS Spaces membership query" section of SPECIFICATION-IMPLEMENTATION.md.
///
/// Symbol binding: the `CGS*` symbols below are private and undocumented but exposed by
/// the SDK as aliases on `CoreGraphics.framework` (which AppKit transitively links), so
/// no extra linker flags are required. The same calls are also exported from the
/// private `SkyLight.framework` under `SLS*` names; we use the CGS aliases.
///
/// Memory: by CF naming convention this Copy function appears to return a +1 retained
/// CFArray, matching how community CGS wrappers (Amethyst, AeroSpace, Hammerspoon) treat
/// it. Swift does not infer CF ownership for `@_silgen_name` declarations — there is no
/// Clang importer metadata to consult — so we make the contract explicit by returning
/// `Unmanaged<CFArray>?` and calling `takeRetainedValue()` ourselves.
import AppKit

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

/// Observed `CGSSpaceType` value for native full-screen Spaces. Other values exist for
/// user / system / tiled Spaces but are not stable across releases in the literature, so
/// only the marker we actually need is documented here.
private let kCGSSpaceTypeFullscreen: Int32 = 4

/// Observed all-Spaces mask used to include non-current and full-screen Spaces in the
/// query. The exact bit semantics are private; this value matches what other CGS wrappers
/// pass when they want "every Space, regardless of which is current".
private let kCGSAllSpacesMask: Int32 = 7

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(
    _ cid: CGSConnectionID,
    _ mask: Int32,
    _ windowIDs: CFArray
) -> Unmanaged<CFArray>?

@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(
    _ cid: CGSConnectionID,
    _ sid: CGSSpaceID
) -> Int32

enum SpaceQueries {
    /// Returns `true` if `cgWindowId` currently belongs to a native macOS full-screen Space.
    /// Returns `false` if the window is in a regular user Space, or if the query fails for any reason.
    /// Failures are logged at most once per call to aid diagnosis if CGS stops returning data.
    static func isWindowInNativeFullScreenSpace(cgWindowId: CGWindowID) -> Bool {
        let cid = CGSMainConnectionID()
        let windowIDs = [NSNumber(value: UInt32(cgWindowId))] as CFArray
        guard let unmanaged = CGSCopySpacesForWindows(cid, kCGSAllSpacesMask, windowIDs) else {
            Logger.debug("SpaceQueries: CGSCopySpacesForWindows returned nil for CGWindowID \(cgWindowId)")
            return false
        }
        let spacesArray = unmanaged.takeRetainedValue()
        guard let spaces = spacesArray as? [NSNumber] else {
            Logger.debug("SpaceQueries: CGSCopySpacesForWindows returned non-array for CGWindowID \(cgWindowId)")
            return false
        }
        for spaceNumber in spaces {
            let spaceId = spaceNumber.uint64Value
            if CGSSpaceGetType(cid, spaceId) == kCGSSpaceTypeFullscreen {
                return true
            }
        }
        return false
    }
}
