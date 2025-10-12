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

        if allPassed {
            print("ZoneLayoutTests: all tests passed")
        }
        return allPassed
    }
}
