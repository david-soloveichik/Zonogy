/// Pure policy for suppressing inherited Launcher clicks until the pointer moves.

import CoreGraphics

struct LauncherClickSuppressionGate {
    static let movementTolerance: CGFloat = 6

    private(set) var anchorScreenPoint: CGPoint?

    var isArmed: Bool {
        anchorScreenPoint != nil
    }

    mutating func arm(at screenPoint: CGPoint) {
        anchorScreenPoint = screenPoint
    }

    mutating func clear() {
        anchorScreenPoint = nil
    }

    mutating func notePointerLocation(_ screenPoint: CGPoint) {
        guard let anchorScreenPoint else {
            return
        }
        if Self.hasPointerMoved(anchor: anchorScreenPoint, current: screenPoint) {
            clear()
        }
    }

    mutating func shouldSuppressLauncherPointerEvent(
        at screenPoint: CGPoint,
        targetsLauncher: Bool
    ) -> Bool {
        notePointerLocation(screenPoint)
        guard targetsLauncher, isArmed else {
            return false
        }
        return true
    }

    static func hasPointerMoved(
        anchor: CGPoint,
        current: CGPoint,
        tolerance: CGFloat = movementTolerance
    ) -> Bool {
        hypot(current.x - anchor.x, current.y - anchor.y) > tolerance
    }
}
