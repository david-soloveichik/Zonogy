import CoreGraphics

/// Lightweight runtime assertions for Sticky Resize tiled-frame selection.
enum StickyResizeFramePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("StickyResizeFramePolicyTests: \(message)")
                allPassed = false
            }
        }

        let zoneFrame = CGRect(x: 8, y: 8, width: 952, height: 1064)
        let rememberedSize = CGSize(width: 1200, height: 900)

        let inactive = StickyResizeFramePolicy.nonRevealedFrame(
            zoneFrame: zoneFrame,
            rememberedSize: rememberedSize,
            stickyResizeEnabled: true,
            isActive: false
        )
        assert(inactive.frame == zoneFrame, "inactive windows should stay at the zone frame")
        assert(!inactive.usesRememberedSize, "inactive windows should not use the remembered size")

        let disabled = StickyResizeFramePolicy.nonRevealedFrame(
            zoneFrame: zoneFrame,
            rememberedSize: rememberedSize,
            stickyResizeEnabled: false,
            isActive: true
        )
        assert(disabled.frame == zoneFrame, "Sticky Resize disabled should use the zone frame")
        assert(!disabled.usesRememberedSize, "Sticky Resize disabled should ignore remembered sizes")

        let active = StickyResizeFramePolicy.nonRevealedFrame(
            zoneFrame: zoneFrame,
            rememberedSize: rememberedSize,
            stickyResizeEnabled: true,
            isActive: true
        )
        assert(active.frame.origin == zoneFrame.origin, "remembered active frame should stay anchored to the zone origin")
        assert(active.frame.size == rememberedSize, "remembered active frame should use the remembered size")
        assert(active.usesRememberedSize, "active Sticky Resize windows should report remembered-size usage")

        let invalidRememberedSize = StickyResizeFramePolicy.nonRevealedFrame(
            zoneFrame: zoneFrame,
            rememberedSize: CGSize(width: 0, height: 500),
            stickyResizeEnabled: true,
            isActive: true
        )
        assert(
            invalidRememberedSize.frame == zoneFrame,
            "invalid remembered sizes should fall back to the zone frame"
        )

        if allPassed {
            print("StickyResizeFramePolicyTests: all tests passed")
        }
        return allPassed
    }
}
