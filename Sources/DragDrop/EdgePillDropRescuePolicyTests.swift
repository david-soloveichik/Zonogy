import Foundation
import CoreGraphics

/// Lightweight assertions for the edge-pill drop-rescue dead band.
enum EdgePillDropRescuePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertBand(
            cursor: CGFloat,
            edge: CGFloat,
            interiorIsBelowEdge: Bool,
            expected: Bool,
            label: String
        ) {
            let actual = EdgePillDropRescuePolicy.isInDeadBand(
                cursor: cursor,
                edge: edge,
                interiorIsBelowEdge: interiorIsBelowEdge
            )
            if actual != expected {
                print("EdgePillDropRescuePolicyTests: \(label) failed (expected \(expected), got \(actual))")
                allPassed = false
            }
        }

        // Bottom edge of a screen above the primary (edge at accessibility y = 0, interior above).
        assertBand(cursor: -0.015625, edge: 0, interiorIsBelowEdge: true, expected: true,
                   label: "pinned cursor just inside bottom edge rescues")
        assertBand(cursor: 0, edge: 0, interiorIsBelowEdge: true, expected: true,
                   label: "cursor exactly on bottom boundary rescues")
        assertBand(cursor: -3, edge: 0, interiorIsBelowEdge: true, expected: false,
                   label: "cursor well inside the pill uses the AppKit path")

        // Right edge (interior has smaller x than the edge).
        assertBand(cursor: 418.984375, edge: 419, interiorIsBelowEdge: true, expected: true,
                   label: "pinned cursor just inside right edge rescues")
        assertBand(cursor: 414, edge: 419, interiorIsBelowEdge: true, expected: false,
                   label: "cursor in the right pill interior uses the AppKit path")

        // Left edge (interior has larger x than the edge).
        assertBand(cursor: -2140.984375, edge: -2141, interiorIsBelowEdge: false, expected: true,
                   label: "pinned cursor just inside left edge rescues")
        assertBand(cursor: -2136, edge: -2141, interiorIsBelowEdge: false, expected: false,
                   label: "cursor in the left pill interior uses the AppKit path")

        if allPassed {
            print("EdgePillDropRescuePolicyTests: all tests passed")
        }
        return allPassed
    }
}
