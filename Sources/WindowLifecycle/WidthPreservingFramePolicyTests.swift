import Foundation
import CoreGraphics

/// Lightweight runtime assertions for width-preserving per-app frame exceptions.
enum WidthPreservingFramePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WidthPreservingFramePolicyTests: \(message)")
                allPassed = false
            }
        }

        let requested = CGRect(x: 100, y: 50, width: 500, height: 700)
        let current = CGRect(x: 20, y: 10, width: 860, height: 640)

        let preserved = WidthPreservingFramePolicy.resolvedFrame(
            requestedFrame: requested,
            currentFrame: current,
            preserveWidth: true
        )
        assert(preserved.origin == requested.origin, "width-preserving mode should keep the requested origin")
        assert(preserved.size.width == current.width, "width-preserving mode should reuse the current width")
        assert(preserved.size.height == requested.height, "width-preserving mode should still use the requested height")

        let disabled = WidthPreservingFramePolicy.resolvedFrame(
            requestedFrame: requested,
            currentFrame: current,
            preserveWidth: false
        )
        assert(disabled == requested, "disabled width preservation should return the requested frame unchanged")

        let missingCurrent = WidthPreservingFramePolicy.resolvedFrame(
            requestedFrame: requested,
            currentFrame: nil,
            preserveWidth: true
        )
        assert(missingCurrent == requested, "missing current frame should fall back to the requested frame")

        let invalidCurrent = WidthPreservingFramePolicy.resolvedFrame(
            requestedFrame: requested,
            currentFrame: CGRect(x: 0, y: 0, width: 0, height: 400),
            preserveWidth: true
        )
        assert(invalidCurrent == requested, "invalid current widths should fall back to the requested frame")

        if allPassed {
            print("WidthPreservingFramePolicyTests: all tests passed")
        }
        return allPassed
    }
}
