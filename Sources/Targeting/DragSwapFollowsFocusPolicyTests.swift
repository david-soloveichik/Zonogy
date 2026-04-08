import Foundation
import CoreGraphics

/// Guardrail tests for follows-focus retargeting after tiled window exchanges.
enum DragSwapFollowsFocusPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("DragSwapFollowsFocusPolicyTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2
        let sourceKey = ZoneKey(screenId: screen1, index: 1)
        let targetKey = ZoneKey(screenId: screen2, index: 2)

        do {
            let result = DragSwapFollowsFocusPolicy.targetAfterExchange(
                targetingMode: .followsFocus,
                sourceKey: sourceKey,
                targetKey: targetKey,
                displacedWindowId: 22
            )
            assert(result == targetKey, "should retarget to the dragged window's destination zone after an exchange in follows-focus mode")
        }

        do {
            let result = DragSwapFollowsFocusPolicy.targetAfterExchange(
                targetingMode: .independentOfFocus,
                sourceKey: sourceKey,
                targetKey: targetKey,
                displacedWindowId: 22
            )
            assert(result == nil, "should not retarget after an exchange outside follows-focus mode")
        }

        do {
            let result = DragSwapFollowsFocusPolicy.targetAfterExchange(
                targetingMode: .followsFocus,
                sourceKey: nil,
                targetKey: targetKey,
                displacedWindowId: 22
            )
            assert(result == nil, "should not treat a no-origin placement as a tiled exchange")
        }

        do {
            let result = DragSwapFollowsFocusPolicy.targetAfterExchange(
                targetingMode: .followsFocus,
                sourceKey: sourceKey,
                targetKey: targetKey,
                displacedWindowId: nil
            )
            assert(result == nil, "should not retarget when the drop did not displace another tiled window")
        }

        if allPassed {
            print("DragSwapFollowsFocusPolicyTests: all tests passed")
        }
        return allPassed
    }
}
