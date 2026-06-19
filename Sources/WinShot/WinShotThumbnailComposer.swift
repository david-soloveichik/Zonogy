/// Builds an abstract WinShot thumbnail by capturing each zone-occupant window individually (via the
/// private SkyLight window-server capture, so minimized windows work too) and compositing them onto a
/// blank canvas at their zone positions — no desktop, wallpaper, other apps, or Zonogy chrome.
/// Result delivered on the main queue.
import AppKit

enum WinShotThumbnailComposer {
    /// A window to draw and where to draw it. `destRect` is in screen coordinates (y:0 at display top).
    struct Placement {
        let cgWindowId: CGWindowID
        let destRect: CGRect
    }

    // Visual constants (canvas space).
    private static let backgroundColor = NSColor(white: 0.12, alpha: 1.0)
    private static let emptyZoneStrokeColor = NSColor(white: 0.34, alpha: 1.0)
    private static let missingWindowFillColor = NSColor(white: 0.24, alpha: 1.0)
    private static let cornerRadius: CGFloat = 2.0
    private static let tileInset: CGFloat = 1.5  // gap so adjacent tiles read as separate

    /// Off-main queue for the (synchronous) window-server captures, so they never stall the caller.
    private static let captureQueue = DispatchQueue(label: "com.dsemeas.zonogy.winshot.thumbnail", qos: .utility)

    /// Capture each placement's window and composite them into a thumbnail of height `targetHeight`.
    /// `completion` is always invoked on the main queue. Windows that can't be captured are drawn as
    /// flat placeholder blocks so the layout still reads.
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
        // windows), then composite on the main queue. ≤4 windows; a window that can't be captured is
        // left out and rendered as a placeholder block.
        let allPlacements = tiled + (floating.map { [$0] } ?? [])
        captureQueue.async {
            var capturedImages: [CGWindowID: CGImage] = [:]
            for placement in allPlacements {
                if let image = WindowServerCapture.captureWindowImage(cgWindowId: placement.cgWindowId) {
                    capturedImages[placement.cgWindowId] = image
                }
            }
            DispatchQueue.main.async {
                let image = render(
                    displaySize: displaySize,
                    targetHeight: targetHeight,
                    tiled: tiled,
                    floating: floating,
                    emptyZoneRects: emptyZoneRects,
                    capturedImages: capturedImages
                )
                completion(image)
            }
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

        // Background.
        backgroundColor.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        // Empty-zone outlines.
        emptyZoneStrokeColor.setStroke()
        for rect in emptyZoneRects {
            let outline = NSBezierPath(roundedRect: canvasRect(rect), xRadius: cornerRadius, yRadius: cornerRadius)
            outline.lineWidth = 1.0
            outline.stroke()
        }

        // Tiled windows, then the floating window on top.
        for placement in tiled {
            draw(placement: placement, captured: capturedImages[placement.cgWindowId], in: canvasRect(placement.destRect))
        }
        if let floating {
            draw(placement: floating, captured: capturedImages[floating.cgWindowId], in: canvasRect(floating.destRect))
        }

        return image
    }

    /// Draw one window into `rect` (aspect-fill, anchored top-left, clipped to the rounded rect), or a
    /// flat placeholder block when the window couldn't be captured.
    private static func draw(placement: Placement, captured: CGImage?, in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }

        guard let captured else {
            missingWindowFillColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return
        }

        let imageWidth = CGFloat(captured.width)
        let imageHeight = CGFloat(captured.height)
        guard imageWidth > 0, imageHeight > 0 else { return }

        // Aspect-fill: scale to cover the rect; anchor the image's top-left to the rect's top-left so the
        // top-left of the window shows and any overflow is cropped (mirrors a window tiled into its zone).
        let fillScale = max(rect.width / imageWidth, rect.height / imageHeight)
        let drawnSize = CGSize(width: imageWidth * fillScale, height: imageHeight * fillScale)
        let drawRect = CGRect(
            x: rect.minX,
            y: rect.maxY - drawnSize.height,
            width: drawnSize.width,
            height: drawnSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        NSImage(cgImage: captured, size: NSSize(width: imageWidth, height: imageHeight))
            .draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
    }
}
