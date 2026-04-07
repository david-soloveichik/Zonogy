import Foundation
import CoreGraphics

/// Support utilities for per-app "snap to zone on self-resize" behavior.
///
/// This is intentionally heuristic: we only need to distinguish user edge-drag resizes
/// (where the user is interacting with the window border) from internal/app-driven resizes.
struct WindowResizeHeuristics {
    static func isCursorNearWindowEdge(
        cursorPoint: CGPoint,
        windowFrame: CGRect,
        edgeProximity: CGFloat
    ) -> Bool {
        guard edgeProximity > 0,
              windowFrame.width > 0,
              windowFrame.height > 0 else {
            return false
        }

        // Require the cursor to be close to the window at all (expanded bounds),
        // then classify as a likely edge resize if it's within the edge threshold.
        let expandedBounds = windowFrame.insetBy(dx: -edgeProximity, dy: -edgeProximity)
        guard expandedBounds.contains(cursorPoint) else {
            return false
        }

        let nearLeft = abs(cursorPoint.x - windowFrame.minX) <= edgeProximity
        let nearRight = abs(cursorPoint.x - windowFrame.maxX) <= edgeProximity
        let nearTop = abs(cursorPoint.y - windowFrame.minY) <= edgeProximity
        let nearBottom = abs(cursorPoint.y - windowFrame.maxY) <= edgeProximity
        return nearLeft || nearRight || nearTop || nearBottom
    }

    static func isLikelyUserEdgeDragResize(
        cursorPoint: CGPoint,
        windowFrame: CGRect,
        edgeProximity: CGFloat,
        leftMouseButtonDown: Bool,
        secondsSinceLeftMouseUp: TimeInterval,
        mouseUpGrace: TimeInterval
    ) -> Bool {
        guard isCursorNearWindowEdge(
            cursorPoint: cursorPoint,
            windowFrame: windowFrame,
            edgeProximity: edgeProximity
        ) else {
            return false
        }

        if leftMouseButtonDown {
            return true
        }

        if secondsSinceLeftMouseUp <= mouseUpGrace {
            return true
        }

        return false
    }
}

/// Pure policy for deciding how a snap-exception window should react to a resize event.
enum WindowSelfResizePolicy {
    enum Action: Equatable {
        /// Treat the resize as a real user edge drag and refresh Sticky Resize tracking.
        case updateManualResizeTracking
        /// Ignore the event because the window is already detached and this does not look user-driven.
        case ignoreWhileDetached
        /// Snap the window back to its zone because the resize looks app-driven.
        case snapToZone
    }

    static func action(
        isAlreadyDetached: Bool,
        isLikelyUserResize: Bool
    ) -> Action {
        if isLikelyUserResize {
            return .updateManualResizeTracking
        }

        if isAlreadyDetached {
            return .ignoreWhileDetached
        }

        return .snapToZone
    }
}

/// Debounces repeated attempts to snap the same window to the same target frame.
struct WindowFrameDebouncer {
    private struct Entry {
        let frame: CGRect
        let timestamp: TimeInterval
    }

    private var entries: [Int: Entry] = [:]
    let minimumInterval: TimeInterval
    let frameTolerance: CGFloat

    init(minimumInterval: TimeInterval, frameTolerance: CGFloat = 2.0) {
        self.minimumInterval = minimumInterval
        self.frameTolerance = frameTolerance
    }

    mutating func shouldAllow(
        windowId: Int,
        targetFrame: CGRect,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        if let existing = entries[windowId],
           framesClose(existing.frame, targetFrame),
           now - existing.timestamp < minimumInterval {
            return false
        }

        entries[windowId] = Entry(frame: targetFrame, timestamp: now)
        return true
    }

    mutating func clear(windowId: Int) {
        entries.removeValue(forKey: windowId)
    }

    private func framesClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= frameTolerance &&
            abs(lhs.minY - rhs.minY) <= frameTolerance &&
            abs(lhs.width - rhs.width) <= frameTolerance &&
            abs(lhs.height - rhs.height) <= frameTolerance
    }
}
