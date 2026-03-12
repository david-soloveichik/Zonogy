import Foundation
import CoreGraphics

/// Simple assertions for ZoneResizeHandleGeometry clipping behavior.
enum ZoneResizeHandleGeometryTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertEqual(_ actual: CGRect?, _ expected: CGRect?, label: String) {
            switch (actual, expected) {
            case (nil, nil):
                return
            case let (.some(actualRect), .some(expectedRect)):
                if !actualRect.equalTo(expectedRect) {
                    print("ZoneResizeHandleGeometryTests: \(label) failed\n  expected: \(expectedRect)\n  actual:   \(actualRect)")
                    allPassed = false
                }
            default:
                print("ZoneResizeHandleGeometryTests: \(label) failed\n  expected: \(expected as Any)\n  actual:   \(actual as Any)")
                allPassed = false
            }
        }

        // No overlap → unchanged.
        do {
            let separator = CGRect(x: 50, y: 0, width: 8, height: 100)
            let avoid = CGRect(x: 0, y: 200, width: 200, height: 50)
            let clipped = ZoneResizeHandleGeometry.clippedSeparatorFrame(separator, avoiding: avoid, orientation: .vertical)
            assertEqual(clipped, separator, label: "no-overlap returns original (vertical)")
        }

        // Vertical overlap: clip to the larger remaining segment (ties keep the top).
        do {
            let separator = CGRect(x: 50, y: 0, width: 8, height: 100)
            let avoid = CGRect(x: 0, y: 40, width: 200, height: 20)
            let expected = CGRect(x: 50, y: 0, width: 8, height: 40)
            let clipped = ZoneResizeHandleGeometry.clippedSeparatorFrame(separator, avoiding: avoid, orientation: .vertical)
            assertEqual(clipped, expected, label: "vertical clip chooses largest segment")
        }

        // Vertical full cover → hide.
        do {
            let separator = CGRect(x: 50, y: 0, width: 8, height: 100)
            let avoid = CGRect(x: 0, y: -10, width: 200, height: 200)
            let clipped = ZoneResizeHandleGeometry.clippedSeparatorFrame(separator, avoiding: avoid, orientation: .vertical)
            assertEqual(clipped, nil, label: "vertical full cover returns nil")
        }

        // Horizontal overlap: clip to the larger remaining segment (ties keep the left).
        do {
            let separator = CGRect(x: 0, y: 50, width: 100, height: 8)
            let avoid = CGRect(x: 40, y: 0, width: 20, height: 200)
            let expected = CGRect(x: 0, y: 50, width: 40, height: 8)
            let clipped = ZoneResizeHandleGeometry.clippedSeparatorFrame(separator, avoiding: avoid, orientation: .horizontal)
            assertEqual(clipped, expected, label: "horizontal clip chooses largest segment")
        }

        // Horizontal full cover → hide.
        do {
            let separator = CGRect(x: 0, y: 50, width: 100, height: 8)
            let avoid = CGRect(x: -10, y: 0, width: 200, height: 200)
            let clipped = ZoneResizeHandleGeometry.clippedSeparatorFrame(separator, avoiding: avoid, orientation: .horizontal)
            assertEqual(clipped, nil, label: "horizontal full cover returns nil")
        }

        // Minimum visible region steers clipping toward the placeholder-aligned side.
        do {
            let separator = CGRect(x: 50, y: 0, width: 8, height: 100)
            let avoid = CGRect(x: 0, y: 40, width: 200, height: 20)
            let minimum = CGRect(x: 50, y: 80, width: 8, height: 20)
            let expected = CGRect(x: 50, y: 60, width: 8, height: 40)
            let clipped = ZoneResizeHandleGeometry.clippedSeparatorFrame(
                separator,
                avoiding: avoid,
                orientation: .vertical,
                minimumVisibleFrame: minimum
            )
            assertEqual(clipped, expected, label: "minimum visible region chooses matching side")
        }

        // If the required pinned segment itself overlaps, keep that minimum instead of hiding.
        do {
            let separator = CGRect(x: 50, y: 0, width: 8, height: 100)
            let avoid = CGRect(x: 0, y: 40, width: 200, height: 20)
            let minimum = CGRect(x: 50, y: 20, width: 8, height: 30)
            let clipped = ZoneResizeHandleGeometry.clippedSeparatorFrame(
                separator,
                avoiding: avoid,
                orientation: .vertical,
                minimumVisibleFrame: minimum
            )
            assertEqual(clipped, minimum, label: "minimum visible region survives overlapping clip")
        }

        // Inset helper keeps expected margins for normal-sized frames.
        do {
            let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
            let inset = ZoneResizeHandleGeometry.insetAvoidanceFrame(frame, by: 8)
            let expected = CGRect(x: 18, y: 28, width: 184, height: 84)
            assertEqual(inset, expected, label: "inset helper applies symmetric inset")
        }

        // Inset helper preserves at least 1px dimensions.
        do {
            let frame = CGRect(x: 10, y: 20, width: 2, height: 2)
            let inset = ZoneResizeHandleGeometry.insetAvoidanceFrame(frame, by: 8)
            let expected = CGRect(x: 10.5, y: 20.5, width: 1, height: 1)
            assertEqual(inset, expected, label: "inset helper clamps to minimum size")
        }

        if allPassed {
            print("ZoneResizeHandleGeometryTests: all tests passed")
        }
        return allPassed
    }
}
