import Foundation
import CoreGraphics

/// Lightweight runtime assertions for CoordinateConversion and ScreenDescriptor conversions.
enum CoordinateConversionTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertApproximatelyEqual(_ actual: CGFloat, _ expected: CGFloat, label: String, tolerance: CGFloat = 0.5) {
            if abs(actual - expected) > tolerance {
                print("CoordinateConversionTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
            }
        }

        func assertApproximatelyEqual(_ actual: CGRect, _ expected: CGRect, label: String, tolerance: CGFloat = 0.5) {
            assertApproximatelyEqual(actual.origin.x, expected.origin.x, label: "\(label) x", tolerance: tolerance)
            assertApproximatelyEqual(actual.origin.y, expected.origin.y, label: "\(label) y", tolerance: tolerance)
            assertApproximatelyEqual(actual.size.width, expected.size.width, label: "\(label) width", tolerance: tolerance)
            assertApproximatelyEqual(actual.size.height, expected.size.height, label: "\(label) height", tolerance: tolerance)
        }

        do {
            let screenBounds = CGRect(x: -1440, y: -100, width: 1440, height: 900)
            let cocoaFrame = CGRect(x: -1200, y: 50, width: 300, height: 200)

            let screenFrame = CoordinateConversion.cocoaToScreen(cocoaFrame: cocoaFrame, screenBounds: screenBounds)
            let roundTrip = CoordinateConversion.screenToCocoa(screenFrame: screenFrame, screenBounds: screenBounds)

            assertApproximatelyEqual(roundTrip, cocoaFrame, label: "cocoa→screen→cocoa roundtrip")
        }

        do {
            let screenBounds = CGRect(x: 100, y: 20, width: 1920, height: 1080)
            let screenFrame = CGRect(x: 40, y: 60, width: 500, height: 400)

            let cocoaFrame = CoordinateConversion.screenToCocoa(screenFrame: screenFrame, screenBounds: screenBounds)
            let roundTrip = CoordinateConversion.cocoaToScreen(cocoaFrame: cocoaFrame, screenBounds: screenBounds)

            assertApproximatelyEqual(roundTrip, screenFrame, label: "screen→cocoa→screen roundtrip")
        }

        do {
            let primaryBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let cocoaFrame = CGRect(x: -1400, y: 200, width: 500, height: 300)

            let accessibility = CoordinateConversion.cocoaToAccessibility(cocoaFrame: cocoaFrame, primaryScreenBounds: primaryBounds)
            let roundTrip = CoordinateConversion.accessibilityToCocoa(accessibilityFrame: accessibility, primaryScreenBounds: primaryBounds)

            assertApproximatelyEqual(roundTrip, cocoaFrame, label: "cocoa→accessibility→cocoa roundtrip")
        }

        do {
            let primaryBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let cocoaBounds = CGRect(x: -1440, y: 0, width: 1440, height: 900)
            let visibleCocoaBounds = CGRect(x: -1440, y: 0, width: 1440, height: 850)

            let descriptor = ScreenDescriptor(
                displayId: 2,
                localizedName: "Test Display",
                cocoaBounds: cocoaBounds,
                visibleCocoaBounds: visibleCocoaBounds,
                primaryBounds: primaryBounds
            )

            let expectedVisibleScreenBounds = CoordinateConversion.cocoaToScreen(
                cocoaFrame: visibleCocoaBounds,
                screenBounds: cocoaBounds
            )
            assertApproximatelyEqual(descriptor.visibleScreenBounds, expectedVisibleScreenBounds, label: "visibleScreenBounds conversion")

            let screenFrame = CGRect(x: 120, y: 70, width: 600, height: 500)
            let accessibility = descriptor.screenToAccessibility(screenFrame)
            let roundTrip = descriptor.accessibilityToScreen(accessibility)
            assertApproximatelyEqual(roundTrip, screenFrame, label: "screen→accessibility→screen roundtrip via ScreenDescriptor")
        }

        if allPassed {
            print("CoordinateConversionTests: all tests passed")
        }
        return allPassed
    }
}
