import Foundation
import CoreGraphics

/// Simple assertions for ZoneLayout geometry across the layout styles
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

        func assertTrue(_ condition: Bool, label: String) {
            if !condition {
                print("ZoneLayoutTests: \(label) failed")
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

        func assertTiling(_ frames: [CGRect], label: String) {
            assertNoOverlaps(frames, label: label)
            for (index, frame) in frames.enumerated() {
                assertRectWithinScreen(frame, label: "\(label) frame \(index + 1)")
            }
            let totalArea = frames.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            assertApproximatelyEqual(
                totalArea / (screen.width * screen.height), 1.0,
                label: "\(label) total area"
            )
        }

        let halfWidth = screen.width / 2
        let halfHeight = screen.height / 2
        let leftHalf = CGRect(x: screen.minX, y: screen.minY, width: halfWidth, height: screen.height)
        let rightHalf = CGRect(x: screen.minX + halfWidth, y: screen.minY, width: halfWidth, height: screen.height)
        let leftTop = CGRect(x: screen.minX, y: screen.minY, width: halfWidth, height: halfHeight)
        let leftBottom = CGRect(x: screen.minX, y: screen.minY + halfHeight, width: halfWidth, height: halfHeight)
        let rightTop = CGRect(x: screen.minX + halfWidth, y: screen.minY, width: halfWidth, height: halfHeight)
        let rightBottom = CGRect(x: screen.minX + halfWidth, y: screen.minY + halfHeight, width: halfWidth, height: halfHeight)

        // Single zone fills the screen regardless of nominal side.
        for side in ZoneSide.allCases {
            let single = ZoneLayout.computeFrames(sides: [side], screenFrame: screen)
            if let frame = single.first {
                assertEqual(frame, screen, label: "1 zone (side \(side.rawValue))")
            }
        }

        // Right-bar canonical shapes: zone 1 left, zones 2/3 stack on the right.
        let rightBarTwo = ZoneLayout.computeFrames(sides: [.left, .right], screenFrame: screen)
        assertEqual(rightBarTwo[0], leftHalf, label: "right-bar 2 zones (zone 1 left)")
        assertEqual(rightBarTwo[1], rightHalf, label: "right-bar 2 zones (zone 2 right)")
        assertTiling(rightBarTwo, label: "right-bar 2 zones")

        let rightBarThree = ZoneLayout.computeFrames(sides: [.left, .right, .right], screenFrame: screen)
        assertEqual(rightBarThree[0], leftHalf, label: "right-bar 3 zones (zone 1 left)")
        assertEqual(rightBarThree[1], rightTop, label: "right-bar 3 zones (zone 2 right-top)")
        assertEqual(rightBarThree[2], rightBottom, label: "right-bar 3 zones (zone 3 right-bottom)")
        assertTiling(rightBarThree, label: "right-bar 3 zones")

        // Left-bar mirror: zone 1 right, zones 2/3 stack on the left (zone 2 on top).
        let leftBarThree = ZoneLayout.computeFrames(sides: [.right, .left, .left], screenFrame: screen)
        assertEqual(leftBarThree[0], rightHalf, label: "left-bar 3 zones (zone 1 right)")
        assertEqual(leftBarThree[1], leftTop, label: "left-bar 3 zones (zone 2 left-top)")
        assertEqual(leftBarThree[2], leftBottom, label: "left-bar 3 zones (zone 3 left-bottom)")
        assertTiling(leftBarThree, label: "left-bar 3 zones")

        // Dual-bar 2x2: index order carries creation order; row = index order within a side.
        let dualFour = ZoneLayout.computeFrames(sides: [.left, .right, .right, .left], screenFrame: screen)
        assertEqual(dualFour[0], leftTop, label: "dual 4 zones (zone 1 left-top)")
        assertEqual(dualFour[1], rightTop, label: "dual 4 zones (zone 2 right-top)")
        assertEqual(dualFour[2], rightBottom, label: "dual 4 zones (zone 3 right-bottom)")
        assertEqual(dualFour[3], leftBottom, label: "dual 4 zones (zone 4 left-bottom)")
        assertTiling(dualFour, label: "dual 4 zones")

        // Dual-bar 3 zones stacked on the left with a right single (path-dependent arrangement).
        let dualLeftStack = ZoneLayout.computeFrames(sides: [.right, .left, .left], screenFrame: screen)
        assertTiling(dualLeftStack, label: "dual 3 zones (left stack)")

        // Degenerate one-sided stack (transient state): the lone column spans the full width.
        let fullWidthStack = ZoneLayout.computeFrames(sides: [.left, .left], screenFrame: screen)
        assertEqual(
            fullWidthStack[0],
            CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: halfHeight),
            label: "one-sided stack (top)"
        )
        assertEqual(
            fullWidthStack[1],
            CGRect(x: screen.minX, y: screen.minY + halfHeight, width: screen.width, height: halfHeight),
            label: "one-sided stack (bottom)"
        )

        // Resizing a zone adjusts the column split (and stack split for stacked zones).
        var adjustableLayout = ZoneLayout()
        let proposedLeft = CGRect(x: screen.minX, y: screen.minY, width: 400, height: screen.height)
        adjustableLayout.resize(zoneIndex: 1, sides: [.left, .right], screenFrame: screen, to: proposedLeft)
        let resizedTwo = adjustableLayout.frames(sides: [.left, .right], screenFrame: screen)
        assertApproximatelyEqual(resizedTwo[0].width, 400, label: "resized 2 zones (left width)")
        assertApproximatelyEqual(resizedTwo[1].width, screen.width - 400, label: "resized 2 zones (right width)")
        assertApproximatelyEqual(resizedTwo[0].maxX, resizedTwo[1].minX, label: "resized 2 zones boundary alignment")

        let proposedTopRight = CGRect(x: screen.minX + 400, y: screen.minY, width: screen.width - 400, height: 300)
        adjustableLayout.resize(zoneIndex: 2, sides: [.left, .right, .right], screenFrame: screen, to: proposedTopRight)
        let resizedThree = adjustableLayout.frames(sides: [.left, .right, .right], screenFrame: screen)
        assertApproximatelyEqual(resizedThree[0].width, 400, label: "resized 3 zones (left width)")
        assertApproximatelyEqual(resizedThree[1].height, 300, label: "resized 3 zones (top height)")
        assertApproximatelyEqual(resizedThree[2].height, screen.height - 300, label: "resized 3 zones (bottom height)")
        assertNoOverlaps(resizedThree, label: "resized 3 zones")

        // Resizing a bottom stacked zone in a mirrored arrangement updates that side's split.
        var mirroredLayout = ZoneLayout()
        let proposedLeftBottom = CGRect(x: screen.minX, y: screen.minY + 650, width: 500, height: 250)
        mirroredLayout.resize(zoneIndex: 3, sides: [.right, .left, .left], screenFrame: screen, to: proposedLeftBottom)
        let mirroredFrames = mirroredLayout.frames(sides: [.right, .left, .left], screenFrame: screen)
        assertApproximatelyEqual(mirroredFrames[2].height, 250, label: "mirrored resize (left-bottom height)")
        assertApproximatelyEqual(mirroredFrames[1].height, screen.height - 250, label: "mirrored resize (left-top height)")
        assertApproximatelyEqual(mirroredFrames[0].width, screen.width - 500, label: "mirrored resize (right zone width from left zone)")

        // Per-side stack splits are independent in the dual-bar 2x2.
        var dualLayout = ZoneLayout()
        dualLayout.resizeBySeparator(id: .horizontal(.left), delta: 150, screenFrame: screen)
        let dualFrames = dualLayout.frames(sides: [.left, .right, .right, .left], screenFrame: screen)
        assertApproximatelyEqual(dualFrames[0].height, halfHeight + 150, label: "dual left stack split moved")
        assertApproximatelyEqual(dualFrames[1].height, halfHeight, label: "dual right stack split unchanged")
        assertTiling(dualFrames, label: "dual 4 zones after left split resize")

        // Separator identity and geometry per arrangement.
        do {
            let layout = ZoneLayout()
            let sides: [ZoneSide] = [.left, .right]
            let frames = layout.frames(sides: sides, screenFrame: screen)
            let separators = layout.separators(sides: sides, screenFrame: screen)
            assertTrue(separators.count == 1, label: "2 zones separator count")
            if let separator = separators.first {
                assertTrue(separator.id == .vertical, label: "2 zones separator identity")
                assertApproximatelyEqual(separator.frame.midX, frames[0].maxX, label: "2-zone separator x alignment")
                assertApproximatelyEqual(separator.frame.height, screen.height, label: "2-zone separator height")
            }
        }

        do {
            let layout = ZoneLayout()
            let sides: [ZoneSide] = [.right, .left, .left]
            let frames = layout.frames(sides: sides, screenFrame: screen)
            let separators = layout.separators(sides: sides, screenFrame: screen)
            assertTrue(separators.count == 2, label: "left-bar 3 zones separator count")
            let vertical = separators.first { $0.id == .vertical }
            let horizontal = separators.first { $0.id == .horizontal(.left) }
            assertTrue(vertical != nil, label: "left-bar 3 zones has vertical separator")
            assertTrue(horizontal != nil, label: "left-bar 3 zones has left horizontal separator")
            assertTrue(!separators.contains { $0.id == .horizontal(.right) }, label: "left-bar 3 zones has no right horizontal separator")
            if let horizontal {
                assertApproximatelyEqual(horizontal.frame.midY, frames[1].maxY, label: "left-bar horizontal separator y alignment")
                assertApproximatelyEqual(horizontal.frame.width, frames[1].width, label: "left-bar horizontal separator width")
                assertApproximatelyEqual(horizontal.frame.minX, screen.minX, label: "left-bar horizontal separator on left column")
            }
        }

        do {
            let layout = ZoneLayout()
            let sides: [ZoneSide] = [.left, .right, .right, .left]
            let separators = layout.separators(sides: sides, screenFrame: screen)
            assertTrue(separators.count == 3, label: "dual 4 zones separator count")
            assertTrue(separators.contains { $0.id == .vertical }, label: "dual 4 zones has vertical separator")
            assertTrue(separators.contains { $0.id == .horizontal(.left) }, label: "dual 4 zones has left horizontal separator")
            assertTrue(separators.contains { $0.id == .horizontal(.right) }, label: "dual 4 zones has right horizontal separator")
        }

        do {
            let layout = ZoneLayout()
            let separators = layout.separators(sides: [.left], screenFrame: screen)
            assertTrue(separators.isEmpty, label: "single zone has no separators")
        }

        // Extreme separator drags clamp ratios.
        do {
            var layout = ZoneLayout()
            layout.resizeBySeparator(id: .vertical, delta: -100_000, screenFrame: screen)
            let frames = layout.frames(sides: [.left, .right], screenFrame: screen)
            assertApproximatelyEqual(frames[0].width, screen.width * 0.1, label: "vertical separator clamp (min)")
        }

        do {
            var layout = ZoneLayout()
            layout.resizeBySeparator(id: .vertical, delta: 100_000, screenFrame: screen)
            let frames = layout.frames(sides: [.left, .right], screenFrame: screen)
            assertApproximatelyEqual(frames[0].width, screen.width * 0.9, label: "vertical separator clamp (max)")
        }

        do {
            var layout = ZoneLayout()
            layout.resizeBySeparator(id: .horizontal(.right), delta: -100_000, screenFrame: screen)
            let frames = layout.frames(sides: [.left, .right, .right], screenFrame: screen)
            assertApproximatelyEqual(frames[1].height, screen.height * 0.1, label: "horizontal separator clamp (min)")
        }

        do {
            var layout = ZoneLayout()
            layout.resizeBySeparator(id: .horizontal(.right), delta: 100_000, screenFrame: screen)
            let frames = layout.frames(sides: [.left, .right, .right], screenFrame: screen)
            assertApproximatelyEqual(frames[1].height, screen.height * 0.9, label: "horizontal separator clamp (max)")
        }

        // Layout style capacity and canonical-side derivations.
        assertTrue(ZoneLayoutStyle.rightBar.maxZoneCount == 3, label: "right-bar max zones")
        assertTrue(ZoneLayoutStyle.leftBar.maxZoneCount == 3, label: "left-bar max zones")
        assertTrue(ZoneLayoutStyle.dualBar.maxZoneCount == 4, label: "dual-bar max zones")
        assertTrue(ZoneLayoutStyle.rightBar.fixedSides(zoneCount: 3) == [.left, .right, .right], label: "right-bar fixed sides")
        assertTrue(ZoneLayoutStyle.leftBar.fixedSides(zoneCount: 3) == [.right, .left, .left], label: "left-bar fixed sides")
        assertTrue(ZoneLayoutStyle.dualBar.fixedSides(zoneCount: 3) == nil, label: "dual-bar sides are stateful")
        assertTrue(ZoneLayoutStyle.dualBar.canonicalSides(zoneCount: 4) == [.left, .right, .right, .left], label: "dual-bar canonical fill")

        if allPassed {
            print("ZoneLayoutTests: all tests passed")
        }
        return allPassed
    }
}
