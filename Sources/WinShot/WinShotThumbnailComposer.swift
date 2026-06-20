/// Builds an abstract WinShot thumbnail by capturing each zone-occupant window individually (via the
/// private SkyLight window-server capture, so minimized windows work too) and compositing them onto a
/// blank canvas at their zone positions — no desktop, wallpaper, other apps, or Zonogy chrome.
/// A window caught mid-minimize captures nothing on the first try, so missing windows are re-captured
/// a few times before falling back to a placeholder tile. Result delivered on the main queue.
import AppKit

enum WinShotThumbnailComposer {
    /// A window to draw and where to draw it. `destRect` is in screen coordinates (y:0 at display top).
    struct Placement {
        let cgWindowId: CGWindowID
        let destRect: CGRect
    }

    // Visual constants (canvas space). Colors sampled from the desired mockup: a light warm-gray
    // canvas, light-blue empty-zone tiles, and a medium-blue tile border.
    private static let backgroundColor = NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.94, alpha: 1.0)
    private static let emptyZoneFillColor = NSColor(calibratedRed: 0.87, green: 0.90, blue: 0.96, alpha: 1.0)
    private static let zoneBorderColor = NSColor(calibratedRed: 0.39, green: 0.54, blue: 0.83, alpha: 1.0)
    private static let missingWindowFillColor = NSColor(white: 0.82, alpha: 1.0)
    private static let cornerRadius: CGFloat = 4.0
    private static let borderWidth: CGFloat = 1.5
    private static let tileInset: CGFloat = 2.0  // gap so adjacent tiles read as separate

    /// Off-main queue for the (synchronous) window-server captures, so they never stall the caller.
    private static let captureQueue = DispatchQueue(label: "com.dsemeas.zonogy.winshot.thumbnail", qos: .utility)

    /// Total capture attempts per thumbnail (1 initial + retries). A window captured the instant it is
    /// being minimized — e.g. the outgoing floating occupant minimized during a chooser switch — returns
    /// no image while the macOS minimize genie animation is mid-flight. `CGSHWCaptureWindowList` succeeds
    /// again once the window settles into its minimized state, so we re-capture only the still-missing
    /// windows instead of rendering a permanent gray placeholder.
    private static let maxCaptureAttempts = 4
    /// Delay between capture attempts. Attempts land at ~0.0/0.2/0.4/0.6s, so the later retries fall
    /// past the minimize genie (~0.25s) once the window has settled and is capturable again. See
    /// SPECIFICATION-TIMERS.md.
    private static let captureRetryDelay: TimeInterval = 0.2

    /// Capture each placement's window and composite them into a thumbnail of height `targetHeight`.
    /// `completion` is always invoked on the main queue, exactly once. Windows that still can't be
    /// captured after the retries are drawn as flat placeholder blocks so the layout still reads.
    static func composeThumbnail(
        displaySize: CGSize,
        tiled: [Placement],
        floating: Placement?,
        emptyZoneRects: [CGRect],
        targetHeight: CGFloat,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard displaySize.width > 0, displaySize.height > 0 else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // Capture each window by CGWindowID via the private window-server API (works for minimized
        // windows), then composite on the main queue. ≤4 windows. Each attempt re-captures only the
        // windows still missing an image; a window mid-minimize fails now but succeeds on a later
        // attempt once its minimized backing store settles.
        let allPlacements = tiled + (floating.map { [$0] } ?? [])

        func attemptCapture(_ attempt: Int, _ capturedSoFar: [CGWindowID: CGImage]) {
            var captured = capturedSoFar
            for placement in allPlacements where captured[placement.cgWindowId] == nil {
                if let image = WindowServerCapture.captureWindowImage(cgWindowId: placement.cgWindowId) {
                    captured[placement.cgWindowId] = image
                }
            }

            let missing = allPlacements.filter { captured[$0.cgWindowId] == nil }
            if !missing.isEmpty, attempt < maxCaptureAttempts {
                logCapture(missing: missing, floating: floating, attempt: attempt, gaveUp: false)
                captureQueue.asyncAfter(deadline: .now() + captureRetryDelay) {
                    attemptCapture(attempt + 1, captured)
                }
                return
            }
            if !missing.isEmpty {
                logCapture(missing: missing, floating: floating, attempt: attempt, gaveUp: true)
            }

            DispatchQueue.main.async {
                let image = render(
                    displaySize: displaySize,
                    targetHeight: targetHeight,
                    tiled: tiled,
                    floating: floating,
                    emptyZoneRects: emptyZoneRects,
                    capturedImages: captured
                )
                completion(image)
            }
        }

        captureQueue.async { attemptCapture(1, [:]) }
    }

    /// Log windows whose capture returned no image, tagging the floating occupant since it is the most
    /// common casualty (the outgoing floating window minimized during a chooser switch). Closes the gap
    /// where a failed capture silently became a gray tile with nothing in the log.
    private static func logCapture(missing: [Placement], floating: Placement?, attempt: Int, gaveUp: Bool) {
        let list = missing
            .map { "\($0.cgWindowId == floating?.cgWindowId ? "floating" : "tiled") cgWindowId \($0.cgWindowId)" }
            .joined(separator: ", ")
        if gaveUp {
            Logger.debug("WinShot thumbnail: capture failed for [\(list)] after \(attempt) attempt(s); rendering placeholder tile(s)")
        } else {
            Logger.debug("WinShot thumbnail: no capture for [\(list)] (attempt \(attempt)/\(maxCaptureAttempts)); retrying in \(captureRetryDelay)s")
        }
    }

    // MARK: - Rendering (main queue)

    private static func render(
        displaySize: CGSize,
        targetHeight: CGFloat,
        tiled: [Placement],
        floating: Placement?,
        emptyZoneRects: [CGRect],
        capturedImages: [CGWindowID: CGImage]
    ) -> NSImage {
        let scale = targetHeight / displaySize.height
        let canvasSize = NSSize(width: (displaySize.width * scale).rounded(), height: targetHeight)

        // Map a screen-coordinate rect (y:0 at top) to an inset canvas rect (bottom-left origin).
        func canvasRect(_ screenRect: CGRect) -> CGRect {
            let x = screenRect.minX * scale
            let width = screenRect.width * scale
            let height = screenRect.height * scale
            let yFromBottom = canvasSize.height - (screenRect.minY * scale) - height
            return CGRect(x: x, y: yFromBottom, width: width, height: height)
                .insetBy(dx: tileInset, dy: tileInset)
        }

        let image = NSImage(size: canvasSize)
        image.lockFocus()
        defer { image.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high

        // Background (light gray).
        backgroundColor.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        // Empty zones: light-blue filled, bordered tiles.
        for rect in emptyZoneRects {
            let tile = NSBezierPath(roundedRect: canvasRect(rect), xRadius: cornerRadius, yRadius: cornerRadius)
            emptyZoneFillColor.setFill()
            tile.fill()
            strokeBorder(tile)
        }

        // Occupied tiled windows, then the floating window on top.
        for placement in tiled {
            draw(placement: placement, captured: capturedImages[placement.cgWindowId], in: canvasRect(placement.destRect))
        }
        if let floating {
            draw(placement: floating, captured: capturedImages[floating.cgWindowId], in: canvasRect(floating.destRect))
        }

        return image
    }

    /// Draw one occupied zone tile into `rect`: the window image (aspect-fill, anchored top-left,
    /// clipped to the rounded rect) or a flat placeholder block when the window couldn't be captured —
    /// always framed with the zone border so it matches the empty-zone tiles.
    private static func draw(placement: Placement, captured: CGImage?, in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let tile = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        if let captured, captured.width > 0, captured.height > 0 {
            let imageWidth = CGFloat(captured.width)
            let imageHeight = CGFloat(captured.height)
            // Aspect-fill: scale to cover the rect; anchor the image's top-left to the rect's top-left so
            // the top-left of the window shows and any overflow is cropped (mirrors a window in its zone).
            let fillScale = max(rect.width / imageWidth, rect.height / imageHeight)
            let drawnSize = CGSize(width: imageWidth * fillScale, height: imageHeight * fillScale)
            let drawRect = CGRect(
                x: rect.minX,
                y: rect.maxY - drawnSize.height,
                width: drawnSize.width,
                height: drawnSize.height
            )
            NSGraphicsContext.saveGraphicsState()
            tile.addClip()
            NSImage(cgImage: captured, size: NSSize(width: imageWidth, height: imageHeight))
                .draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Window exists but couldn't be captured: neutral placeholder block.
            missingWindowFillColor.setFill()
            tile.fill()
        }

        strokeBorder(tile)
    }

    private static func strokeBorder(_ tile: NSBezierPath) {
        zoneBorderColor.setStroke()
        tile.lineWidth = borderWidth
        tile.stroke()
    }
}
