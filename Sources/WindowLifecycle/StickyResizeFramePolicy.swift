import CoreGraphics

/// Computes the non-revealed tiled frame when Sticky Resize may restore a remembered active size.
enum StickyResizeFramePolicy {
    struct Resolution {
        let frame: CGRect
        let usesRememberedSize: Bool
    }

    static func nonRevealedFrame(
        zoneFrame: CGRect,
        rememberedSize: CGSize?,
        stickyResizeEnabled: Bool,
        isActive: Bool
    ) -> Resolution {
        guard stickyResizeEnabled,
              isActive,
              let rememberedSize,
              rememberedSize.width > 0,
              rememberedSize.height > 0 else {
            return Resolution(frame: zoneFrame, usesRememberedSize: false)
        }

        return Resolution(
            frame: CGRect(origin: zoneFrame.origin, size: rememberedSize),
            usesRememberedSize: true
        )
    }
}
