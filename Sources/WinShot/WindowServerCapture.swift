/// Synchronous window-image capture via the private SkyLight `CGSHWCaptureWindowList` API.
///
/// Unlike ScreenCaptureKit (`SCScreenshotManager.captureImage`), this reads a window's backing
/// store, so it captures **minimized / off-screen windows** too (returning their last-rendered
/// content) and returns immediately instead of blocking until the window is on-screen again.
/// WinShot needs this because the pre-clear/pre-switch thumbnail captures run as their windows are
/// being minimized — ScreenCaptureKit blocks on those until they reappear, leaving empty thumbnails.
///
/// This mirrors how AltTab captures thumbnails where ScreenCaptureKit can't (it uses this same call
/// on macOS where SCK can't screenshot minimized windows). The `CGS*` symbols are private/undocumented
/// SkyLight aliases on CoreGraphics. The `CGSConnectionID` typealias is declared module-wide in
/// [SpaceQueries.swift](../FullScreen/SpaceQueries.swift) and reused; `CGSMainConnectionID` is
/// re-declared file-private below (a second `@_silgen_name` binding to the same SkyLight symbol).
///
/// Memory: by CF convention the returned CFArray is +1 retained, and `@_silgen_name` carries no
/// ownership metadata, so we declare `Unmanaged<CFArray>?` and call `takeRetainedValue()` ourselves.
import AppKit

/// Capture flags for `CGSHWCaptureWindowList`. Bit values are private/undocumented; these match the
/// values used by AltTab and other CGS wrappers.
struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32
    /// Capture without the window's global clip shape (rounded corners, etc.).
    static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    /// 1x (logical) resolution — a quarter of the pixels of `bestResolution` on Retina; ample for a
    /// small thumbnail and cheaper to capture and downscale.
    static let nominalResolution = CGSWindowCaptureOptions(rawValue: 1 << 9)
    /// Native (Retina) resolution.
    static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
    /// Full-size capture regardless of Stage Manager skew.
    static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
}

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSHWCaptureWindowList")
private func CGSHWCaptureWindowList(
    _ cid: CGSConnectionID,
    _ windowList: UnsafeMutablePointer<CGWindowID>,
    _ windowCount: UInt32,
    _ options: CGSWindowCaptureOptions
) -> Unmanaged<CFArray>?

enum WindowServerCapture {
    /// Capture a single window's image by CGWindowID, including minimized / off-screen windows.
    /// Synchronous; returns nil if the window can't be captured (e.g. it no longer exists).
    static func captureWindowImage(cgWindowId: CGWindowID) -> CGImage? {
        var windowId = cgWindowId
        // CGSHWCaptureWindowList only honors the first id in the list, so capture one window at a time.
        guard let unmanaged = CGSHWCaptureWindowList(
            CGSMainConnectionID(),
            &windowId,
            1,
            [.ignoreGlobalClipShape, .nominalResolution, .fullSize]
        ) else {
            return nil
        }
        let images = unmanaged.takeRetainedValue() as? [CGImage]
        return images?.first
    }
}
