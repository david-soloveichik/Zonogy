import Foundation
import CoreGraphics

/// Guardrail coverage for ZoneResizeHandleVisibilityPolicy overlap rules.
enum ZoneResizeHandleVisibilityPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertEqual(_ actual: CGRect?, _ expected: CGRect?, label: String) {
            switch (actual, expected) {
            case (nil, nil):
                return
            case let (.some(actualRect), .some(expectedRect)):
                if !actualRect.equalTo(expectedRect) {
                    print("ZoneResizeHandleVisibilityPolicyTests: \(label) failed\n  expected: \(expectedRect)\n  actual:   \(actualRect)")
                    allPassed = false
                }
            default:
                print("ZoneResizeHandleVisibilityPolicyTests: \(label) failed\n  expected: \(expected as Any)\n  actual:   \(actual as Any)")
                allPassed = false
            }
        }

        let vertical = ZoneLayout.Separator(
            index: 0,
            orientation: .vertical,
            frame: CGRect(x: 50, y: 0, width: 8, height: 100)
        )
        let horizontal = ZoneLayout.Separator(
            index: 1,
            orientation: .horizontal,
            frame: CGRect(x: 0, y: 50, width: 100, height: 8)
        )

        // No overlap contexts leaves separators unchanged.
        do {
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: nil,
                frontmostManagedContext: nil
            )
            assertEqual(adjusted, vertical.frame, label: "no-context unchanged")
        }

        // ActiveFit in right-column zone clips the vertical separator.
        do {
            let active = ZoneResizeHandleAvoidanceContext(
                zoneIndex: 2,
                avoidFrame: CGRect(x: 0, y: 40, width: 200, height: 20)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: active,
                frontmostManagedContext: nil
            )
            assertEqual(
                adjusted,
                CGRect(x: 50, y: 0, width: 8, height: 40),
                label: "activefit clips vertical separator"
            )
        }

        // ActiveFit in right-column zone hides horizontal separator on overlap.
        do {
            let active = ZoneResizeHandleAvoidanceContext(
                zoneIndex: 2,
                avoidFrame: CGRect(x: 40, y: 0, width: 20, height: 200)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                horizontal,
                activeFitContext: active,
                frontmostManagedContext: nil
            )
            assertEqual(adjusted, nil, label: "activefit hides horizontal separator")
        }

        // Frontmost zone-1 window clips overlapping vertical separator.
        do {
            let frontmost = ZoneResizeHandleAvoidanceContext(
                zoneIndex: 1,
                avoidFrame: CGRect(x: 48, y: 20, width: 20, height: 20)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: nil,
                frontmostManagedContext: frontmost
            )
            assertEqual(
                adjusted,
                CGRect(x: 50, y: 40, width: 8, height: 60),
                label: "frontmost zone1 clips vertical separator"
            )
        }

        // Frontmost window in zone 3 also clips vertical separator.
        do {
            let frontmost = ZoneResizeHandleAvoidanceContext(
                zoneIndex: 3,
                avoidFrame: CGRect(x: 48, y: 20, width: 20, height: 20)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: nil,
                frontmostManagedContext: frontmost
            )
            assertEqual(
                adjusted,
                CGRect(x: 50, y: 40, width: 8, height: 60),
                label: "frontmost zone3 clips vertical separator"
            )
        }

        // Frontmost window hides vertical separator when fully covered.
        do {
            let frontmost = ZoneResizeHandleAvoidanceContext(
                zoneIndex: 2,
                avoidFrame: CGRect(x: 40, y: 0, width: 40, height: 200)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: nil,
                frontmostManagedContext: frontmost
            )
            assertEqual(adjusted, nil, label: "frontmost hides fully-covered vertical separator")
        }

        // Frontmost window clips horizontal separator regardless of zone.
        do {
            let frontmost = ZoneResizeHandleAvoidanceContext(
                zoneIndex: 3,
                avoidFrame: CGRect(x: 40, y: 0, width: 20, height: 200)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                horizontal,
                activeFitContext: nil,
                frontmostManagedContext: frontmost
            )
            assertEqual(
                adjusted,
                CGRect(x: 0, y: 50, width: 40, height: 8),
                label: "frontmost clips horizontal separator"
            )
        }

        // ActiveFit adjustments are applied before frontmost rules.
        do {
            let active = ZoneResizeHandleAvoidanceContext(
                zoneIndex: 2,
                avoidFrame: CGRect(x: 0, y: 40, width: 200, height: 20)
            )
            let frontmost = ZoneResizeHandleAvoidanceContext(
                zoneIndex: 1,
                avoidFrame: CGRect(x: 48, y: 10, width: 20, height: 20)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: active,
                frontmostManagedContext: frontmost
            )
            assertEqual(
                adjusted,
                CGRect(x: 50, y: 0, width: 8, height: 10),
                label: "frontmost can further clip activefit-clipped separator"
            )
        }

        if allPassed {
            print("ZoneResizeHandleVisibilityPolicyTests: all tests passed")
        }
        return allPassed
    }
}
