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

        // Sheet overhang measurement: sheets wider than the window overhang left and right;
        // edges inside the window contribute nothing.
        let overhangWindow = CGRect(x: 1200, y: 100, width: 300, height: 900)
        let measured = ActiveFitPolicy.attachmentOverhang(
            windowFrame: overhangWindow,
            attachedFrames: [
                CGRect(x: 1100, y: 120, width: 600, height: 500),
                CGRect(x: 1250, y: 150, width: 200, height: 900)
            ]
        )
        assert(measured.left == 100, "sheet extending left of the window should measure left overhang (expected 100, got \(measured.left))")
        assert(measured.right == 200, "sheet extending right of the window should measure right overhang (expected 200, got \(measured.right))")
        assert(measured.top == 0, "sheet starting below the window top should not measure top overhang")
        assert(measured.bottom == 50, "sheet ending below the window bottom should measure bottom overhang (expected 50, got \(measured.bottom))")
        assert(
            ActiveFitPolicy.attachmentOverhang(windowFrame: overhangWindow, attachedFrames: []) == .none,
            "no attached frames should measure no overhang"
        )

        // A window that fits by itself still reveals when its sheet overhang pokes off screen.
        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: rightTop,
            zoneOrigin: CGPoint(x: 1300, y: 0),
            windowSize: CGSize(width: 300, height: 500),
            overhang: ActiveFitPolicy.AttachmentOverhang(left: 400, right: 400),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.x == 1220, "sheet overhang overflow should shift the window left (expected 1220, got \(frame.origin.x))")
            assert(frame.origin.y == 0, "horizontal sheet overhang should not shift vertically")
        } else {
            assert(false, "expected ActiveFit to reveal for sheet overhang past the right screen edge")
        }

        let sheetFits = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: rightTop,
            zoneOrigin: CGPoint(x: 1300, y: 0),
            windowSize: CGSize(width: 300, height: 500),
            overhang: ActiveFitPolicy.AttachmentOverhang(left: 100, right: 100),
            screenBounds: bounds,
            tolerance: tolerance
        )
        assert(sheetFits == nil, "ActiveFit should not trigger when window and sheet overhang both fit on screen")

        // The reveal shift stops where the sheet's own left edge would leave the screen.
        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: rightTop,
            zoneOrigin: CGPoint(x: 960, y: 0),
            windowSize: CGSize(width: 300, height: 500),
            overhang: ActiveFitPolicy.AttachmentOverhang(left: 200, right: 1600),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.x == 200, "reveal shift should clamp so the sheet's left edge stays on screen (expected 200, got \(frame.origin.x))")
        } else {
            assert(false, "expected ActiveFit to reveal for an oversized sheet overhang")
        }

        // A sheet taller than its window reveals with an upward shift.
        if let frame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: rightBottom,
            zoneOrigin: CGPoint(x: 1280, y: 640),
            windowSize: CGSize(width: 500, height: 400),
            overhang: ActiveFitPolicy.AttachmentOverhang(bottom: 100),
            screenBounds: bounds,
            tolerance: tolerance
        ) {
            assert(frame.origin.y == 580, "bottom sheet overhang should shift the window up (expected 580, got \(frame.origin.y))")
            assert(frame.origin.x == 1280, "vertical sheet overhang should not shift horizontally")
        } else {
            assert(false, "expected ActiveFit to reveal for sheet overhang past the bottom screen edge")
        }

        if allPassed {
            print("ActiveFitPolicyTests: all tests passed")
        }
        return allPassed
    }
}
