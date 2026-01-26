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

        // Zone 1 rest-mode overflow push (right edge aligned to zone frame)
        let zoneOneFrame = CGRect(x: 8, y: 0, width: 600, height: 800)
        let zoneOneOversized = ActiveFitPolicy.restOriginForZoneOne(
            zoneFrame: zoneOneFrame,
            windowSize: CGSize(width: 700, height: 600),
            tolerance: tolerance
        )
        assert(zoneOneOversized.x == -92, "zone 1 rest origin should align right edge (expected -92, got \(zoneOneOversized.x))")

        let zoneOneFits = ActiveFitPolicy.restOriginForZoneOne(
            zoneFrame: zoneOneFrame,
            windowSize: CGSize(width: 599, height: 600),
            tolerance: tolerance
        )
        assert(zoneOneFits.x == zoneOneFrame.origin.x, "zone 1 rest origin should remain anchored when width fits (expected \(zoneOneFrame.origin.x), got \(zoneOneFits.x))")

        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 2,
            zoneOrigin: CGPoint(x: 1300, y: 0),
            windowSize: CGSize(width: 800, height: 900),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.x == 1120, "right overflow should shift origin left by overflow amount (expected 1120, got \(frame.origin.x))")
            assert(frame.origin.y == 0, "pure horizontal overflow should not shift vertically")
        } else {
            assert(false, "expected ActiveFit to translate horizontally for oversized width in zone 2")
        }

        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 3,
            zoneOrigin: CGPoint(x: 1280, y: 640),
            windowSize: CGSize(width: 900, height: 520),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.x == 1020, "combined overflow should shift left as needed (expected 1020, got \(frame.origin.x))")
            assert(frame.origin.y == 560, "combined overflow should shift up as needed (expected 560, got \(frame.origin.y))")
        } else {
            assert(false, "expected ActiveFit to translate for combined width/height overflow in zone 3")
        }

        let noOverflow = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 2,
            zoneOrigin: CGPoint(x: 960, y: 0),
            windowSize: CGSize(width: 400, height: 500),
            screenBounds: bounds,
            tolerance: tolerance
        )
        assert(noOverflow == nil, "ActiveFit should not trigger when the frame already fits")

        let zoneOneReveal = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 1,
            zoneOrigin: CGPoint(x: -200, y: 0),
            windowSize: CGSize(width: 800, height: 700),
            screenBounds: bounds,
            tolerance: tolerance
        )
        assert(zoneOneReveal?.origin.x == 0, "zone 1 left overflow should clamp origin to minX (expected 0, got \(zoneOneReveal?.origin.x ?? -1))")

        let tinyOverflow = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: 2,
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
