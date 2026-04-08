import CoreGraphics

/// Resolves the effective frame to apply when a per-app exception preserves width.
enum WidthPreservingFramePolicy {
    static func resolvedFrame(
        requestedFrame: CGRect,
        currentFrame: CGRect?,
        preserveWidth: Bool
    ) -> CGRect {
        guard preserveWidth,
              let currentFrame,
              currentFrame.width > 0 else {
            return requestedFrame
        }

        return CGRect(
            origin: requestedFrame.origin,
            size: CGSize(width: currentFrame.width, height: requestedFrame.height)
        )
    }
}
