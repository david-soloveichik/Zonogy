import Foundation
import CoreGraphics

/// Lightweight runtime assertions for ActiveFitPolicy reveal math.
enum ActiveFitPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ActiveFitPolicyTests: \(message)")
                allPassed = false
            }
        }

        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let tolerance: CGFloat = 1.0
        // Zone frames for a 1920x1080 screen split at midline.
        let leftFull = CGRect(x: 0, y: 0, width: 960, height: 1080)
        let rightFull = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let rightTop = CGRect(x: 960, y: 0, width: 960, height: 540)
        let rightBottom = CGRect(x: 960, y: 540, width: 960, height: 540)
        let leftTop = CGRect(x: 0, y: 0, width: 960, height: 540)
        let leftBottom = CGRect(x: 0, y: 540, width: 960, height: 540)

        // Only zones anchored at the screen's top-left corner are exempt from reveal.
        assert(!ActiveFitPolicy.zoneCanReveal(zoneFrame: leftFull, screenBounds: bounds), "top-left-anchored full-height zone cannot reveal")
        assert(!ActiveFitPolicy.zoneCanReveal(zoneFrame: leftTop, screenBounds: bounds), "top-left-anchored stacked zone cannot reveal")
        assert(!ActiveFitPolicy.zoneCanReveal(zoneFrame: bounds, screenBounds: bounds), "single full-screen zone cannot reveal")
        assert(ActiveFitPolicy.zoneCanReveal(zoneFrame: rightFull, screenBounds: bounds), "right-half zone can reveal (left shift)")
        assert(ActiveFitPolicy.zoneCanReveal(zoneFrame: rightTop, screenBounds: bounds), "right-top zone can reveal")
        assert(ActiveFitPolicy.zoneCanReveal(zoneFrame: rightBottom, screenBounds: bounds), "right-bottom zone can reveal")
        assert(ActiveFitPolicy.zoneCanReveal(zoneFrame: leftBottom, screenBounds: bounds), "left-bottom zone can reveal (up shift)")

        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: rightTop,
            zoneOrigin: CGPoint(x: 1300, y: 0),
            windowSize: CGSize(width: 800, height: 900),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.x == 1120, "right overflow should shift origin left by overflow amount (expected 1120, got \(frame.origin.x))")
            assert(frame.origin.y == 0, "pure horizontal overflow should not shift vertically")
        } else {
            assert(false, "expected ActiveFit to translate horizontally for oversized width in a right-column zone")
        }

        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: rightBottom,
            zoneOrigin: CGPoint(x: 1280, y: 640),
            windowSize: CGSize(width: 900, height: 520),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.x == 1020, "combined overflow should shift left as needed (expected 1020, got \(frame.origin.x))")
            assert(frame.origin.y == 560, "combined overflow should shift up as needed (expected 560, got \(frame.origin.y))")
        } else {
            assert(false, "expected ActiveFit to translate for combined width/height overflow in the bottom-right zone")
        }

        // Mirrored layout: a bottom zone of a left stack reveals with an upward shift.
        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: leftBottom,
            zoneOrigin: CGPoint(x: 8, y: 548),
            windowSize: CGSize(width: 500, height: 700),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.y == 380, "bottom overflow should shift up (expected 380, got \(frame.origin.y))")
            assert(frame.origin.x == 8, "pure vertical overflow should not shift horizontally")
        } else {
            assert(false, "expected ActiveFit to translate vertically for oversized height in a left-bottom zone")
        }

        let noOverflow = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: rightTop,
            zoneOrigin: CGPoint(x: 960, y: 0),
            windowSize: CGSize(width: 400, height: 500),
            screenBounds: bounds,
            tolerance: tolerance
        )
        assert(noOverflow == nil, "ActiveFit should not trigger when the frame already fits")

        let cornerZone = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: leftFull,
            zoneOrigin: CGPoint(x: 0, y: 0),
            windowSize: CGSize(width: 2000, height: 1100),
            screenBounds: bounds,
            tolerance: tolerance
        )
        assert(cornerZone == nil, "ActiveFit should ignore the top-left-anchored zone even if it would overflow")

        let tinyOverflow = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: rightTop,
            zoneOrigin: CGPoint(x: 1000, y: 0),
            windowSize: CGSize(width: 920.2, height: 400),
            screenBounds: bounds,
            tolerance: tolerance
        )
        assert(tinyOverflow == nil, "ActiveFit should ignore sub-tolerance overflow")

        if allPassed {
            print("ActiveFitPolicyTests: all tests passed")
        }
        return allPassed
    }
}
