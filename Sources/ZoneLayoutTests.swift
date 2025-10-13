import Foundation
import CoreGraphics

/// Simple assertions for ZoneLayout geometry
enum ZoneLayoutTests {
    @discardableResult
    static func run() -> Bool {
        let screen = CGRect(x: 100, y: 40, width: 1200, height: 900)
        var allPassed = true

        func assertEqual(_ actual: CGRect, _ expected: CGRect, label: String) {
            if !actual.equalTo(expected) {
                print("ZoneLayoutTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
            }
        }

        func assertApproximatelyEqual(_ actual: CGFloat, _ expected: CGFloat, label: String, tolerance: CGFloat = 0.5) {
            if abs(actual - expected) > tolerance {
                print("ZoneLayoutTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
            }
        }

        let single = ZoneLayout.computeFrames(zoneCount: 1, screenFrame: screen)
        if let frame = single.first {
            assertEqual(frame, screen, label: "1 zone")
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
                                          y: screen.minY + halfHeight,
                                          width: halfWidth,
                                          height: halfHeight)
            let expectedBottomRight = CGRect(x: screen.minX + halfWidth,
                                             y: screen.minY,
                                             width: halfWidth,
                                             height: halfHeight)
            assertEqual(splitThree[0], expectedLeft, label: "3 zones (left)")
            assertEqual(splitThree[1], expectedTopRight, label: "3 zones (top-right)")
            assertEqual(splitThree[2], expectedBottomRight, label: "3 zones (bottom-right)")
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
        } else {
            print("ZoneLayoutTests: expected 3 frames for resized 3 zones, got \(resizedThree.count)")
            allPassed = false
        }

        if allPassed {
            print("ZoneLayoutTests: all tests passed")
        }
        return allPassed
    }
}
