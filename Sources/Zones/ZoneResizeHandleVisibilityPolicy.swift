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

/// Avoidance frame for a floating-zone floating window (zone-index-agnostic).
struct ZoneResizeHandleFloatingZoneContext {
    let avoidFrame: CGRect

    init(avoidFrame: CGRect) {
        self.avoidFrame = avoidFrame.standardized
    }
}

/// Applies overlap rules from the specification for ActiveFit reveal windows, frontmost managed windows,
/// and floating-zone floating windows.
enum ZoneResizeHandleVisibilityPolicy {
    private static func clipSeparatorFrame(
        _ frame: CGRect,
        avoiding avoidFrame: CGRect,
        orientation: ZoneLayout.SeparatorOrientation
    ) -> CGRect? {
        ZoneResizeHandleGeometry.clippedSeparatorFrame(
            frame,
            avoiding: avoidFrame,
            orientation: orientation
        )
    }

    private static func adjustedFrameForActiveFitContext(
        _ separator: ZoneLayout.Separator,
        frame: CGRect,
        context: ZoneResizeHandleAvoidanceContext
    ) -> CGRect? {
        var adjusted = frame
        switch separator.orientation {
        case .vertical:
            // Separator between zone 1 and zones 2/3: clip against reveal windows in zones 2/3.
            if separator.index == 0, context.zoneIndex >= 2 {
                guard let clipped = clipSeparatorFrame(
                    adjusted,
                    avoiding: context.avoidFrame,
                    orientation: .vertical
                ) else {
                    return nil
                }
                adjusted = clipped
            }

        case .horizontal:
            // Separator between zones 2 and 3: hide if it intersects reveal windows in zones 2/3.
            if separator.index == 1,
               context.zoneIndex >= 2,
               adjusted.intersects(context.avoidFrame) {
                return nil
            }
        }

        return adjusted
    }

    private static func adjustedFrameForFrontmostContext(
        _ separator: ZoneLayout.Separator,
        frame: CGRect,
        context: ZoneResizeHandleAvoidanceContext
    ) -> CGRect? {
        var adjusted = frame

        // Frontmost managed windows in any tiling zone should avoid both separators.
        if separator.orientation == .vertical,
           separator.index == 0 {
            guard let clipped = clipSeparatorFrame(
                adjusted,
                avoiding: context.avoidFrame,
                orientation: .vertical
            ) else {
                return nil
            }
            adjusted = clipped
        }

        if separator.orientation == .horizontal,
           separator.index == 1 {
            guard let clipped = clipSeparatorFrame(
                adjusted,
                avoiding: context.avoidFrame,
                orientation: .horizontal
            ) else {
                return nil
            }
            adjusted = clipped
        }

        return adjusted
    }

    /// Returns the adjusted frame for a separator, or `nil` if it should be hidden.
    static func adjustedSeparatorFrame(
        _ separator: ZoneLayout.Separator,
        activeFitContext: ZoneResizeHandleAvoidanceContext?,
        frontmostManagedContext: ZoneResizeHandleAvoidanceContext?,
        floatingZoneContext: ZoneResizeHandleFloatingZoneContext? = nil
    ) -> CGRect? {
        var frame = separator.frame.standardized

        // Floating-zone floating window: hide the separator if it overlaps.
        if let floatingZoneContext,
           frame.intersects(floatingZoneContext.avoidFrame) {
            return nil
        }

        if let activeFitContext {
            guard let adjusted = adjustedFrameForActiveFitContext(
                separator,
                frame: frame,
                context: activeFitContext
            ) else {
                return nil
            }
            frame = adjusted
        }

        if let frontmostManagedContext {
            guard let adjusted = adjustedFrameForFrontmostContext(
                separator,
                frame: frame,
                context: frontmostManagedContext
            ) else {
                return nil
            }
            frame = adjusted
        }

        return frame
    }
}
