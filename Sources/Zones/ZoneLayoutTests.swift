import Foundation
import CoreGraphics

/// Simple assertions for ZoneLayout geometry
enum ZoneLayoutTests {
    @discardableResult
    static func run() -> Bool {
        let screen = CGRect(x: 100, y: 40, width: 1200, height: 900)
        var allPassed = true
        let tolerance: CGFloat = 0.5

        func assertEqual(_ actual: CGRect, _ expected: CGRect, label: String) {
            if !actual.equalTo(expected) {
                print("ZoneLayoutTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
            }
        }

        func assertApproximatelyEqual(_ actual: CGFloat, _ expected: CGFloat, label: String) {
            if abs(actual - expected) > tolerance {
                print("ZoneLayoutTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
            }
        }

        func assertRectWithinScreen(_ rect: CGRect, label: String) {
            if rect.minX < screen.minX - tolerance ||
                rect.maxX > screen.maxX + tolerance ||
                rect.minY < screen.minY - tolerance ||
                rect.maxY > screen.maxY + tolerance {
                print("ZoneLayoutTests: \(label) out of bounds\n  screen: \(screen)\n  rect:   \(rect)")
                allPassed = false
            }
        }

        func assertNoOverlaps(_ frames: [CGRect], label: String) {
            for i in 0..<frames.count {
                for j in (i + 1)..<frames.count {
                    let intersection = frames[i].intersection(frames[j])
                    let overlapArea = max(intersection.width, 0) * max(intersection.height, 0)
                    if overlapArea > tolerance {
                        print("ZoneLayoutTests: \(label) overlap between frames \(i) and \(j): \(intersection)")
                        allPassed = false
                    }
                }
            }
        }

        let single = ZoneLayout.computeFrames(zoneCount: 1, screenFrame: screen)
        if let frame = single.first {
            assertEqual(frame, screen, label: "1 zone")
            assertRectWithinScreen(frame, label: "1 zone frame")
        }

        let splitTwo = ZoneLayout.computeFrames(zoneCount: 2, screenFrame: screen)
        if splitTwo.count == 2 {
            let halfWidth = screen.width / 2
            let expectedLeft = CGRect(x: screen.minX,
                                      y: screen.minY,
                                      width: halfWidth,
                                      height: screen.height)
            let expectedRight = CGRect(x: screen.minX + halfWidth,
                                       y: screen.minY,
                                       width: halfWidth,
                                       height: screen.height)
            assertEqual(splitTwo[0], expectedLeft, label: "2 zones (left)")
            assertEqual(splitTwo[1], expectedRight, label: "2 zones (right)")

            assertRectWithinScreen(splitTwo[0], label: "2 zones left frame")
            assertRectWithinScreen(splitTwo[1], label: "2 zones right frame")
            assertApproximatelyEqual(splitTwo[0].width + splitTwo[1].width, screen.width, label: "2 zones total width")
            assertApproximatelyEqual(splitTwo[0].maxX, splitTwo[1].minX, label: "2 zones boundary alignment")
            assertNoOverlaps(splitTwo, label: "2 zones")
        } else {
            print("ZoneLayoutTests: expected 2 frames for 2 zones, got \(splitTwo.count)")
            allPassed = false
        }

        let splitThree = ZoneLayout.computeFrames(zoneCount: 3, screenFrame: screen)
        if splitThree.count == 3 {
            let halfWidth = screen.width / 2
            let halfHeight = screen.height / 2
            let expectedLeft = CGRect(x: screen.minX,
                                      y: screen.minY,
                                      width: halfWidth,
                                      height: screen.height)
            let expectedTopRight = CGRect(x: screen.minX + halfWidth,
                                          y: screen.minY,
                                          width: halfWidth,
                                          height: halfHeight)
            let expectedBottomRight = CGRect(x: screen.minX + halfWidth,
                                             y: screen.minY + halfHeight,
                                             width: halfWidth,
                                             height: halfHeight)
            assertEqual(splitThree[0], expectedLeft, label: "3 zones (left)")
            assertEqual(splitThree[1], expectedTopRight, label: "3 zones (top-right)")
            assertEqual(splitThree[2], expectedBottomRight, label: "3 zones (bottom-right)")

            for (index, frame) in splitThree.enumerated() {
                assertRectWithinScreen(frame, label: "3 zones frame \(index + 1)")
            }
            assertApproximatelyEqual(splitThree[0].width + splitThree[1].width, screen.width, label: "3 zones total width")
            assertApproximatelyEqual(splitThree[1].height + splitThree[2].height, screen.height, label: "3 zones right column total height")
            assertApproximatelyEqual(splitThree[0].maxX, splitThree[1].minX, label: "3 zones vertical boundary alignment")
            assertApproximatelyEqual(splitThree[1].maxY, splitThree[2].minY, label: "3 zones horizontal boundary alignment")
            assertNoOverlaps(splitThree, label: "3 zones")
        } else {
            print("ZoneLayoutTests: expected 3 frames for 3 zones, got \(splitThree.count)")
            allPassed = false
        }

        // Verify resizable behavior adjusts layout ratios.
        var adjustableLayout = ZoneLayout()
        let proposedLeft = CGRect(x: screen.minX,
                                  y: screen.minY,
                                  width: 400,
                                  height: screen.height)
        adjustableLayout.resize(zoneIndex: 1, zoneCount: 2, screenFrame: screen, to: proposedLeft)
        let resizedTwo = adjustableLayout.frames(for: 2, screenFrame: screen)
        if resizedTwo.count == 2 {
            assertApproximatelyEqual(resizedTwo[0].width, 400, label: "resized 2 zones (left width)")
            assertApproximatelyEqual(resizedTwo[1].width, screen.width - 400, label: "resized 2 zones (right width)")
            assertApproximatelyEqual(resizedTwo[0].maxX, resizedTwo[1].minX, label: "resized 2 zones boundary alignment")
            assertNoOverlaps(resizedTwo, label: "resized 2 zones")
        } else {
            print("ZoneLayoutTests: expected 2 frames for resized 2 zones, got \(resizedTwo.count)")
            allPassed = false
        }

        let proposedTopRight = CGRect(x: screen.minX + 400,
                                      y: screen.minY + 600,
                                      width: screen.width - 400,
                                      height: 300)
        adjustableLayout.resize(zoneIndex: 2, zoneCount: 3, screenFrame: screen, to: proposedTopRight)
        let resizedThree = adjustableLayout.frames(for: 3, screenFrame: screen)
        if resizedThree.count == 3 {
            assertApproximatelyEqual(resizedThree[0].width, 400, label: "resized 3 zones (left width)")
            assertApproximatelyEqual(resizedThree[1].height, 300, label: "resized 3 zones (top height)")
            assertApproximatelyEqual(resizedThree[2].height, screen.height - 300, label: "resized 3 zones (bottom height)")
            assertApproximatelyEqual(resizedThree[0].maxX, resizedThree[1].minX, label: "resized 3 zones vertical boundary alignment")
            assertApproximatelyEqual(resizedThree[1].maxY, resizedThree[2].minY, label: "resized 3 zones horizontal boundary alignment")
            assertNoOverlaps(resizedThree, label: "resized 3 zones")
        } else {
            print("ZoneLayoutTests: expected 3 frames for resized 3 zones, got \(resizedThree.count)")
            allPassed = false
        }

        // Verify separator frames align with zone boundaries.
        do {
            let layout = ZoneLayout()
            let frames = layout.frames(for: 2, screenFrame: screen)
            let separators = layout.separators(zoneCount: 2, screenFrame: screen)
            if separators.count == 1 {
                let separator = separators[0]
                assert(separator.orientation == .vertical, "2-zone separator should be vertical")
                assert(separator.index == 0, "2-zone separator index should be 0")
                assertApproximatelyEqual(separator.frame.midX, frames[0].maxX, label: "2-zone separator x alignment")
                assertApproximatelyEqual(separator.frame.height, screen.height, label: "2-zone separator height")
            } else {
                print("ZoneLayoutTests: expected 1 separator for 2 zones, got \(separators.count)")
                allPassed = false
            }
        }

        do {
            let layout = ZoneLayout()
            let frames = layout.frames(for: 3, screenFrame: screen)
            let separators = layout.separators(zoneCount: 3, screenFrame: screen)
            let vertical = separators.first(where: { $0.orientation == .vertical })
            let horizontal = separators.first(where: { $0.orientation == .horizontal })

            if let vertical {
                assert(vertical.index == 0, "3-zone vertical separator index should be 0")
                assertApproximatelyEqual(vertical.frame.midX, frames[0].maxX, label: "3-zone vertical separator x alignment")
                assertApproximatelyEqual(vertical.frame.height, screen.height, label: "3-zone vertical separator height")
            } else {
                print("ZoneLayoutTests: missing vertical separator for 3 zones")
                allPassed = false
            }

            if let horizontal {
                assert(horizontal.index == 1, "3-zone horizontal separator index should be 1")
                assertApproximatelyEqual(horizontal.frame.midY, frames[1].maxY, label: "3-zone horizontal separator y alignment")
                assertApproximatelyEqual(horizontal.frame.width, frames[1].width, label: "3-zone horizontal separator width")
            } else {
                print("ZoneLayoutTests: missing horizontal separator for 3 zones")
                allPassed = false
            }
        }

        // Verify extreme separator drags clamp ratios.
        do {
            var layout = ZoneLayout()
            layout.resizeBySeparator(index: 0, delta: -100_000, zoneCount: 2, screenFrame: screen)
            let frames = layout.frames(for: 2, screenFrame: screen)
            assertApproximatelyEqual(frames[0].width, screen.width * 0.1, label: "vertical separator clamp (min)")
        }

        do {
            var layout = ZoneLayout()
            layout.resizeBySeparator(index: 0, delta: 100_000, zoneCount: 2, screenFrame: screen)
            let frames = layout.frames(for: 2, screenFrame: screen)
            assertApproximatelyEqual(frames[0].width, screen.width * 0.9, label: "vertical separator clamp (max)")
        }

        do {
            var layout = ZoneLayout()
            layout.resizeBySeparator(index: 1, delta: -100_000, zoneCount: 3, screenFrame: screen)
            let frames = layout.frames(for: 3, screenFrame: screen)
            assertApproximatelyEqual(frames[1].height, screen.height * 0.1, label: "horizontal separator clamp (min)")
        }

        do {
            var layout = ZoneLayout()
            layout.resizeBySeparator(index: 1, delta: 100_000, zoneCount: 3, screenFrame: screen)
            let frames = layout.frames(for: 3, screenFrame: screen)
            assertApproximatelyEqual(frames[1].height, screen.height * 0.9, label: "horizontal separator clamp (max)")
        }

        if allPassed {
            print("ZoneLayoutTests: all tests passed")
        }
        return allPassed
    }
}
