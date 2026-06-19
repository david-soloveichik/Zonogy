/// Captures a display's image via ScreenCaptureKit for WinShot thumbnails.
/// Replaces the deprecated CGDisplayCreateImage path with Apple's supported, more
/// energy-efficient capture API. Stateless; results are delivered on the main queue.
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum WinShotScreenCapturer {
    /// Capture the given display as a CGImage. `completion` is always invoked on the main queue,
    /// with `nil` if capture failed (e.g. Screen Recording permission not granted, or the display
    /// is no longer shareable).
    static func captureDisplayImage(
        displayId: CGDirectDisplayID,
        completion: @escaping (CGImage?) -> Void
    ) {
        // `getExcludingDesktopWindows(_:onScreenWindowsOnly:completionHandler:)` is the completion-handler
        // form (the bare `getShareableContent` is async-only as `.current`). The flags only affect the
        // returned window list, which we don't use — we capture the whole display below.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            guard let content,
                  let display = content.displays.first(where: { $0.displayID == displayId }) else {
                DispatchQueue.main.async {
                    Logger.debug(
                        "WinShot: No SCDisplay for \(ScreenContextStore.logDescription(for: displayId)): "
                            + (error?.localizedDescription ?? "no matching shareable display")
                    )
                    completion(nil)
                }
                return
            }

            // Exclude Zonogy's own windows (placeholders, target indicators, edge pills, overlays, the
            // chooser, etc.) so the thumbnail shows the managed-window arrangement rather than Zonogy's
            // chrome. If Zonogy has no on-screen windows this list is empty and the full display is
            // captured. Sizing the output to the display's point dimensions keeps the capture cheap — it
            // is downscaled to a small thumbnail anyway. Hide the cursor so it isn't baked into the image.
            let ownApplications = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = false

            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                DispatchQueue.main.async {
                    if image == nil {
                        Logger.debug(
                            "WinShot: SCScreenshotManager failed for "
                                + "\(ScreenContextStore.logDescription(for: displayId)): "
                                + (error?.localizedDescription ?? "unknown error")
                        )
                    }
                    completion(image)
                }
            }
        }
    }
}
