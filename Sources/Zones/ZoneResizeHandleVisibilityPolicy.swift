import Foundation
import CoreGraphics

/// Pure policy for deciding which resize-handle separators are shown, clipped, or hidden.
struct ZoneResizeHandleAvoidanceContext {
    let zoneIndex: Int
    let avoidFrame: CGRect

    init(zoneIndex: Int, avoidFrame: CGRect) {
        self.zoneIndex = zoneIndex
        self.avoidFrame = avoidFrame.standardized
    }
}

/// Applies overlap rules from the specification for ActiveFit reveal windows and frontmost managed windows.
enum ZoneResizeHandleVisibilityPolicy {
    /// Returns the adjusted frame for a separator, or `nil` if it should be hidden.
    static func adjustedSeparatorFrame(
        _ separator: ZoneLayout.Separator,
        activeFitContext: ZoneResizeHandleAvoidanceContext?,
        frontmostManagedContext: ZoneResizeHandleAvoidanceContext?
    ) -> CGRect? {
        var frame = separator.frame.standardized

        if let activeFitContext {
            switch separator.orientation {
            case .vertical:
                // Separator between zone 1 and zones 2/3: clip against reveal windows in zones 2/3.
                if separator.index == 0, activeFitContext.zoneIndex >= 2 {
                    guard let clipped = ZoneResizeHandleGeometry.clippedSeparatorFrame(
                        frame,
                        avoiding: activeFitContext.avoidFrame,
                        orientation: .vertical
                    ) else {
                        return nil
                    }
                    frame = clipped
                }

            case .horizontal:
                // Separator between zones 2 and 3: hide if it intersects reveal windows in zones 2/3.
                if separator.index == 1,
                   activeFitContext.zoneIndex >= 2,
                   frame.intersects(activeFitContext.avoidFrame) {
                    return nil
                }
            }
        }

        if let frontmostManagedContext {
            // Hide vertical separator when frontmost zone-1 window overlaps the margin.
            if separator.orientation == .vertical,
               separator.index == 0,
               frontmostManagedContext.zoneIndex == 1,
               frame.intersects(frontmostManagedContext.avoidFrame) {
                return nil
            }

            // Clip horizontal separator to avoid the frontmost managed window on any zone.
            if separator.orientation == .horizontal,
               separator.index == 1 {
                guard let clipped = ZoneResizeHandleGeometry.clippedSeparatorFrame(
                    frame,
                    avoiding: frontmostManagedContext.avoidFrame,
                    orientation: .horizontal
                ) else {
                    return nil
                }
                frame = clipped
            }
        }

        return frame
    }
}
