import Foundation
import CoreGraphics

/// Guardrail tests for `DockLocation`: locating the Dock among displays at every point of the
/// auto-hide slide, and deriving its fully revealed frame. Frames are in accessibility coordinates.
enum DockLocationTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func expect(_ condition: Bool, _ label: String) {
            if !condition {
                print("DockLocationTests: \(label) failed")
                allPassed = false
            }
        }

        func display(_ frame: CGRect, menuBar: CGFloat = 0) -> DockLocation.Display {
            DockLocation.Display(
                frame: frame,
                visibleFrame: CGRect(x: frame.minX, y: frame.minY + menuBar, width: frame.width, height: frame.height - menuBar)
            )
        }

        // Layout captured on a real setup: an external display above and to the right of the
        // primary. Its bottom-edge Dock, when hidden, sits just below its bottom edge — which
        // overlaps the primary's top strip in accessibility coordinates.
        let primary = display(CGRect(x: 0, y: 0, width: 1512, height: 982), menuBar: 38)
        let external = display(CGRect(x: 876, y: -1080, width: 1920, height: 1080))
        let displays = [primary, external]

        func resolve(_ list: CGRect, item: CGRect?, orientation: DockOrientation = .horizontal, displays: [DockLocation.Display] = displays) -> DockLocation? {
            DockLocation.resolve(listFrame: list, itemFrame: item, orientation: orientation, displays: displays)
        }

        // Bottom Dock on the primary: the same location whether revealed, mid-slide, or hidden.
        do {
            let revealedList = CGRect(x: 363, y: 936, width: 786, height: 36)
            let expected = DockLocation(display: primary, edge: .bottom, revealedFrame: CGRect(x: 363, y: 941, width: 786, height: 41))
            expect(resolve(revealedList, item: CGRect(x: 744, y: 941, width: 27, height: 36)) == expected, "primary revealed")
            expect(resolve(CGRect(x: 363, y: 971, width: 786, height: 36), item: CGRect(x: 744, y: 976, width: 27, height: 36)) == expected, "primary mid-slide")
            expect(resolve(CGRect(x: 363, y: 982, width: 786, height: 36), item: CGRect(x: 744, y: 987, width: 27, height: 36)) == expected, "primary hidden")
        }

        // Bottom Dock on the external display, including its hidden frame overlapping the primary.
        do {
            let expected = DockLocation(display: external, edge: .bottom, revealedFrame: CGRect(x: 1443, y: -41, width: 786, height: 41))
            expect(resolve(CGRect(x: 1443, y: -46, width: 786, height: 36), item: CGRect(x: 1716, y: -41, width: 27, height: 36)) == expected, "external revealed")
            expect(resolve(CGRect(x: 1443, y: -11, width: 786, height: 36), item: CGRect(x: 1743, y: -6, width: 27, height: 36)) == expected, "external mid-slide")
            expect(resolve(CGRect(x: 1443, y: 0, width: 786, height: 36), item: CGRect(x: 1743, y: 5, width: 27, height: 36)) == expected, "external hidden overlapping primary")
        }

        // Overhang: measured from the item when it extends past the list; default otherwise. List
        // and item frames are sampled separately mid-slide, so the measurement is rounded.
        do {
            let list = CGRect(x: 363, y: 936, width: 786, height: 36)
            expect(resolve(list, item: CGRect(x: 744, y: 944, width: 27, height: 36))?.revealedFrame == CGRect(x: 363, y: 938, width: 786, height: 44), "measured overhang")
            expect(resolve(list, item: CGRect(x: 744, y: 936, width: 27, height: 36))?.revealedFrame.height == 36 + DockLocation.defaultItemOverhang, "same far edge uses default overhang")
            expect(resolve(list, item: nil)?.revealedFrame.height == 36 + DockLocation.defaultItemOverhang, "missing item uses default overhang")
            let skewedList = CGRect(x: 363, y: 971.17, width: 786, height: 36)
            expect(resolve(skewedList, item: CGRect(x: 744, y: 975.83, width: 27, height: 36))?.revealedFrame == CGRect(x: 363, y: 941, width: 786, height: 41), "mid-slide sampling skew rounds away")
        }

        // Vertical Docks: left and right edges, revealed frame flush with the edge.
        do {
            let leftList = CGRect(x: 10, y: 200, width: 36, height: 500)
            let left = resolve(leftList, item: CGRect(x: 5, y: 300, width: 36, height: 27), orientation: .vertical)
            expect(left == DockLocation(display: primary, edge: .left, revealedFrame: CGRect(x: 0, y: 200, width: 41, height: 500)), "left Dock")
            expect(resolve(CGRect(x: -36, y: 200, width: 36, height: 500), item: nil, orientation: .vertical)?.edge == .left, "left Dock hidden")

            let rightList = CGRect(x: 1466, y: 200, width: 36, height: 500)
            let right = resolve(rightList, item: CGRect(x: 1471, y: 300, width: 36, height: 27), orientation: .vertical)
            expect(right == DockLocation(display: primary, edge: .right, revealedFrame: CGRect(x: 1471, y: 200, width: 41, height: 500)), "right Dock")
        }

        // Side-by-side displays, vertically offset: a vertical Dock sliding across their shared
        // boundary hugs both facing edges (when hidden it lies wholly inside the neighbour), and
        // centering along the edge tells them apart.
        do {
            let neighbour = display(CGRect(x: 1512, y: -200, width: 1920, height: 1080))  // midY 340 vs primary's 491
            let sideBySide = [primary, neighbour]
            func check(_ list: CGRect, _ display: DockLocation.Display, _ edge: DockLocation.Edge, _ label: String) {
                let location = resolve(list, item: nil, orientation: .vertical, displays: sideBySide)
                expect(location?.display == display && location?.edge == edge, "shared boundary: \(label)")
            }
            // Right Dock on the primary (centered on y 491): revealed 10pt short of x 1512, mid-slide, hidden.
            check(CGRect(x: 1466, y: 241, width: 36, height: 500), primary, .right, "primary right revealed")
            check(CGRect(x: 1500, y: 241, width: 36, height: 500), primary, .right, "primary right mid-slide")
            check(CGRect(x: 1512, y: 241, width: 36, height: 500), primary, .right, "primary right hidden")
            // Left Dock on the neighbour (centered on y 340): revealed, mid-slide, hidden.
            check(CGRect(x: 1522, y: 90, width: 36, height: 500), neighbour, .left, "neighbour left revealed")
            check(CGRect(x: 1490, y: 90, width: 36, height: 500), neighbour, .left, "neighbour left mid-slide")
            check(CGRect(x: 1476, y: 90, width: 36, height: 500), neighbour, .left, "neighbour left hidden")
        }

        // Displays whose centers align across a shared boundary (equal height, side by side):
        // centering cannot tell the facing edges apart, but the icons lean toward the Dock's edge.
        do {
            let neighbour = display(CGRect(x: 1512, y: 0, width: 1920, height: 982))
            let sideBySide = [primary, neighbour]
            func check(_ list: CGRect, leaning lean: CGFloat, _ display: DockLocation.Display, _ edge: DockLocation.Edge, _ label: String) {
                let item = CGRect(x: list.minX + lean, y: 300, width: 36, height: 27)
                let location = resolve(list, item: item, orientation: .vertical, displays: sideBySide)
                expect(location?.display == display && location?.edge == edge, "aligned centers: \(label)")
            }
            for (x, phase) in [(1466, "revealed"), (1500, "mid-slide"), (1512, "hidden")] {
                check(CGRect(x: CGFloat(x), y: 241, width: 36, height: 500), leaning: 5, primary, .right, "primary right \(phase)")
            }
            for (x, phase) in [(1522, "revealed"), (1490, "mid-slide"), (1476, "hidden")] {
                check(CGRect(x: CGFloat(x), y: 241, width: 36, height: 500), leaning: -5, neighbour, .left, "neighbour left \(phase)")
            }
            let revealed = resolve(CGRect(x: 1522, y: 241, width: 36, height: 500), item: CGRect(x: 1517, y: 300, width: 36, height: 27), orientation: .vertical, displays: sideBySide)
            expect(revealed?.revealedFrame == CGRect(x: 1512, y: 241, width: 41, height: 500), "aligned centers: neighbour left revealed frame")
        }

        // A frame away from every display edge cannot be located.
        expect(resolve(CGRect(x: 363, y: 500, width: 786, height: 36), item: nil) == nil, "frame in display interior resolves to nil")
        expect(resolve(CGRect(x: 363, y: 936, width: 786, height: 36), item: nil, displays: []) == nil, "no displays resolves to nil")

        if allPassed {
            print("DockLocationTests: all tests passed")
        }
        return allPassed
    }
}
