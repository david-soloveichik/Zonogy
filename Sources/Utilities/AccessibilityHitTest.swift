/// Finds what UI is topmost at a screen point, across all applications, through Accessibility.
import ApplicationServices

enum AccessibilityHitTest {
    enum Result<Match> {
        /// The topmost element at the point, or its nearest ancestor, matched.
        case match(Match)
        /// Neither the topmost element nor any of its ancestors matched.
        case noMatch
        /// Accessibility could not tell what is at the point.
        case unavailable
    }

    /// The walk up from the topmost element is bounded, and stops at a repeated element, so a
    /// malformed hierarchy cannot trap it.
    private static let maxDepth = 16

    /// The first non-nil result of `match` for the topmost element at `point` (accessibility
    /// coordinates) or one of its ancestors, nearest first. Used to act on a press only when the UI
    /// meant is what the cursor is really over: overlapping menus, panels, and windows must win.
    static func topmost<Match>(at point: CGPoint, _ match: (AXUIElement) -> Match?) -> Result<Match> {
        var hit: AXUIElement?
        guard AXCall.copyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else {
            return .unavailable
        }
        var element: AXUIElement? = hit
        var visited: Set<CFHashCode> = []
        for _ in 0..<maxDepth {
            guard let current = element, visited.insert(CFHash(current)).inserted else {
                return .noMatch
            }
            if let found = match(current) {
                return .match(found)
            }
            element = parent(of: current)
        }
        return .noMatch
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXCall.copyAttribute(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
