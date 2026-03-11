import Foundation
import CoreGraphics

/// Simple assertions for WindowOcclusionPolicy behavior.
enum WindowOcclusionPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertEqual(_ actual: Bool, _ expected: Bool, label: String) {
            guard actual == expected else {
                print("WindowOcclusionPolicyTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
                return
            }
        }

        // No occluders → not occluded.
        do {
            let target = OcclusionWindow(cgWindowId: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let occluded = WindowOcclusionPolicy.isOccluded(
                target: target,
                occluders: [],
                zOrderFrontToBack: [1]
            )
            assertEqual(occluded, false, label: "no-occluders")
        }

        // Target missing from z-order → not occluded (cannot determine).
        do {
            let target = OcclusionWindow(cgWindowId: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let occluder = OcclusionWindow(cgWindowId: 2, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let occluded = WindowOcclusionPolicy.isOccluded(
                target: target,
                occluders: [occluder],
                zOrderFrontToBack: [2]
            )
            assertEqual(occluded, false, label: "target-missing-from-zorder")
        }

        // Occluder behind target (higher index) → not occluded even if overlapping.
        do {
            let target = OcclusionWindow(cgWindowId: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let occluder = OcclusionWindow(cgWindowId: 2, frame: CGRect(x: 10, y: 10, width: 50, height: 50))
            let occluded = WindowOcclusionPolicy.isOccluded(
                target: target,
                occluders: [occluder],
                zOrderFrontToBack: [1, 2]
            )
            assertEqual(occluded, false, label: "occluder-behind-target")
        }

        // Occluder in front and overlapping → occluded.
        do {
            let target = OcclusionWindow(cgWindowId: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            let occluder = OcclusionWindow(cgWindowId: 2, frame: CGRect(x: 50, y: 50, width: 100, height: 100))
            let occluded = WindowOcclusionPolicy.isOccluded(
                target: target,
                occluders: [occluder],
                zOrderFrontToBack: [2, 1]
            )
            assertEqual(occluded, true, label: "occluder-in-front-overlap")
        }

        // Occluder in front but no overlap → not occluded.
        do {
            let target = OcclusionWindow(cgWindowId: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let occluder = OcclusionWindow(cgWindowId: 2, frame: CGRect(x: 200, y: 0, width: 50, height: 50))
            let occluded = WindowOcclusionPolicy.isOccluded(
                target: target,
                occluders: [occluder],
                zOrderFrontToBack: [2, 1]
            )
            assertEqual(occluded, false, label: "occluder-in-front-no-overlap")
        }

        // Tiny overlap removed by inset → not occluded.
        do {
            let target = OcclusionWindow(cgWindowId: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let occluder = OcclusionWindow(cgWindowId: 2, frame: CGRect(x: 99, y: 0, width: 100, height: 100))
            let occluded = WindowOcclusionPolicy.isOccluded(
                target: target,
                occluders: [occluder],
                zOrderFrontToBack: [2, 1],
                avoidanceInset: 6,
                minIntersectionDimension: 1
            )
            assertEqual(occluded, false, label: "tiny-overlap-ignored")
        }

        // Any in-front occluder overlap → occluded.
        do {
            let target = OcclusionWindow(cgWindowId: 10, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            let behind = OcclusionWindow(cgWindowId: 11, frame: CGRect(x: 50, y: 50, width: 80, height: 80))
            let inFront = OcclusionWindow(cgWindowId: 12, frame: CGRect(x: 60, y: 60, width: 80, height: 80))
            let occluded = WindowOcclusionPolicy.isOccluded(
                target: target,
                occluders: [behind, inFront],
                zOrderFrontToBack: [12, 10, 11]
            )
            assertEqual(occluded, true, label: "any-occluder-in-front")
        }

        // Guardrail: occlusion is based on the supplied zone frame, not a wider revealed window frame.
        do {
            let target = OcclusionWindow(cgWindowId: 20, frame: CGRect(x: 120, y: 0, width: 80, height: 100))
            let zoneFrame = OcclusionWindow(cgWindowId: 21, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let occluded = WindowOcclusionPolicy.isOccluded(
                target: target,
                occluders: [zoneFrame],
                zOrderFrontToBack: [21, 20],
                avoidanceInset: 0,
                minIntersectionDimension: 1
            )
            assertEqual(occluded, false, label: "zone-frame-controls-occlusion-region")
        }

        if allPassed {
            print("WindowOcclusionPolicyTests: all tests passed")
        }
        return allPassed
    }
}
