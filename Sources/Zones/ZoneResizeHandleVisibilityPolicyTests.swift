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
                managedContexts: []
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
                managedContexts: []
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
                managedContexts: []
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
                managedContexts: [frontmost]
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
                managedContexts: [frontmost]
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
                managedContexts: [frontmost]
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
                managedContexts: [frontmost]
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
                managedContexts: [frontmost]
            )
            assertEqual(
                adjusted,
                CGRect(x: 50, y: 0, width: 8, height: 10),
                label: "frontmost can further clip activefit-clipped separator"
            )
        }

        // Floating-zone floating window hides separator on overlap.
        do {
            let floatingCtx = ZoneResizeHandleFloatingZoneContext(
                avoidFrame: CGRect(x: 40, y: 0, width: 30, height: 200)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: nil,
                managedContexts: [],
                floatingZoneContext: floatingCtx
            )
            assertEqual(adjusted, nil, label: "floating zone hides overlapping vertical separator")
        }

        // Floating-zone floating window does not hide non-overlapping separator.
        do {
            let floatingCtx = ZoneResizeHandleFloatingZoneContext(
                avoidFrame: CGRect(x: 70, y: 0, width: 30, height: 200)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: nil,
                managedContexts: [],
                floatingZoneContext: floatingCtx
            )
            assertEqual(adjusted, vertical.frame, label: "floating zone leaves non-overlapping separator")
        }

        // Floating-zone hides horizontal separator on overlap.
        do {
            let floatingCtx = ZoneResizeHandleFloatingZoneContext(
                avoidFrame: CGRect(x: 0, y: 40, width: 200, height: 30)
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                horizontal,
                activeFitContext: nil,
                managedContexts: [],
                floatingZoneContext: floatingCtx
            )
            assertEqual(adjusted, nil, label: "floating zone hides overlapping horizontal separator")
        }

        // Placeholder-aligned pinned context projects placeholder height onto the vertical bar.
        do {
            let pinned = ZoneResizeHandlePinnedContext(
                separator: vertical,
                adjacentPlaceholderFrames: [
                    CGRect(x: 60, y: 4, width: 40, height: 42)
                ]
            )
            assertEqual(
                pinned?.minimumVisibleFrame,
                CGRect(x: 50, y: 4, width: 8, height: 42),
                label: "pinned context projects placeholder extent onto vertical separator"
            )
        }

        // Pinned mode keeps the placeholder-aligned side of the separator visible.
        do {
            let frontmost = ZoneResizeHandleAvoidanceContext(
                zoneIndex: 1,
                avoidFrame: CGRect(x: 48, y: 40, width: 20, height: 20)
            )
            let pinned = ZoneResizeHandlePinnedContext(
                separator: vertical,
                adjacentPlaceholderFrames: [
                    CGRect(x: 60, y: 80, width: 40, height: 20)
                ]
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: nil,
                managedContexts: [frontmost],
                pinnedContext: pinned
            )
            assertEqual(
                adjusted,
                CGRect(x: 50, y: 60, width: 8, height: 40),
                label: "pinned mode clips toward placeholder-aligned side"
            )
        }

        // Pinned mode can survive multiple managed-window clips by preserving the minimum segment.
        do {
            let managedContexts = [
                ZoneResizeHandleAvoidanceContext(
                    zoneIndex: 1,
                    avoidFrame: CGRect(x: 48, y: 0, width: 20, height: 40)
                ),
                ZoneResizeHandleAvoidanceContext(
                    zoneIndex: 3,
                    avoidFrame: CGRect(x: 48, y: 60, width: 20, height: 20)
                )
            ]
            let pinned = ZoneResizeHandlePinnedContext(
                separator: vertical,
                adjacentPlaceholderFrames: [
                    CGRect(x: 60, y: 80, width: 40, height: 20)
                ]
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: nil,
                managedContexts: managedContexts,
                pinnedContext: pinned
            )
            assertEqual(
                adjusted,
                CGRect(x: 50, y: 80, width: 8, height: 20),
                label: "pinned mode preserves minimum through multiple managed clips"
            )
        }

        // Pinned mode clips floating-zone overlap instead of hiding the bar outright.
        do {
            let floatingCtx = ZoneResizeHandleFloatingZoneContext(
                avoidFrame: CGRect(x: 40, y: 0, width: 30, height: 100)
            )
            let pinned = ZoneResizeHandlePinnedContext(
                separator: vertical,
                adjacentPlaceholderFrames: [
                    CGRect(x: 60, y: 70, width: 40, height: 20)
                ]
            )
            let adjusted = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                vertical,
                activeFitContext: nil,
                managedContexts: [],
                floatingZoneContext: floatingCtx,
                pinnedContext: pinned
            )
            assertEqual(
                adjusted,
                CGRect(x: 50, y: 70, width: 8, height: 20),
                label: "pinned floating overlap keeps placeholder minimum"
            )
        }

        if allPassed {
            print("ZoneResizeHandleVisibilityPolicyTests: all tests passed")
        }
        return allPassed
    }
}
