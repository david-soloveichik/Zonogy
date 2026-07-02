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

/// Minimum visible frame enforced while resize bars are pinned by an activated placeholder.
struct ZoneResizeHandlePinnedContext {
    let minimumVisibleFrame: CGRect

    init?(separator: ZoneLayout.Separator, adjacentPlaceholderFrames: [CGRect]) {
        let frames = adjacentPlaceholderFrames
            .map { $0.standardized }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !frames.isEmpty else {
            return nil
        }

        let separatorFrame = separator.frame.standardized
        let frame: CGRect

        switch separator.orientation {
        case .vertical:
            guard let minY = frames.map(\.minY).min(),
                  let maxY = frames.map(\.maxY).max(),
                  maxY > minY else {
                return nil
            }
            frame = CGRect(
                x: separatorFrame.minX,
                y: minY,
                width: separatorFrame.width,
                height: maxY - minY
            )

        case .horizontal:
            guard let minX = frames.map(\.minX).min(),
                  let maxX = frames.map(\.maxX).max(),
                  maxX > minX else {
                return nil
            }
            frame = CGRect(
                x: minX,
                y: separatorFrame.minY,
                width: maxX - minX,
                height: separatorFrame.height
            )
        }

        let clampedFrame = frame.intersection(separatorFrame).standardized
        guard !clampedFrame.isNull,
              clampedFrame.width > 0,
              clampedFrame.height > 0 else {
            return nil
        }
        self.minimumVisibleFrame = clampedFrame
    }
}

/// Applies overlap rules from the specification for ActiveFit reveal windows, frontmost managed windows,
/// pinned placeholder minimums, and floating-zone floating windows.
enum ZoneResizeHandleVisibilityPolicy {
    private static func clipSeparatorFrame(
        _ frame: CGRect,
        avoiding avoidFrame: CGRect,
        orientation: ZoneLayout.SeparatorOrientation,
        minimumVisibleFrame: CGRect?
    ) -> CGRect? {
        ZoneResizeHandleGeometry.clippedSeparatorFrame(
            frame,
            avoiding: avoidFrame,
            orientation: orientation,
            minimumVisibleFrame: minimumVisibleFrame
        )
    }

    private static func adjustedFrameForActiveFitContext(
        _ separator: ZoneLayout.Separator,
        frame: CGRect,
        context: ZoneResizeHandleAvoidanceContext,
        minimumVisibleFrame: CGRect?
    ) -> CGRect? {
        var adjusted = frame
        switch separator.orientation {
        case .vertical:
            // The between-columns separator is shortened so it stays outside the reveal frame.
            guard let clipped = clipSeparatorFrame(
                adjusted,
                avoiding: context.avoidFrame,
                orientation: .vertical,
                minimumVisibleFrame: minimumVisibleFrame
            ) else {
                return nil
            }
            adjusted = clipped

        case .horizontal:
            // In-column separators hide whenever they intersect the reveal frame,
            // unless pinned mode requires a minimum visible segment.
            if adjusted.intersects(context.avoidFrame) {
                guard let minimumVisibleFrame else {
                    return nil
                }
                guard let clipped = clipSeparatorFrame(
                    adjusted,
                    avoiding: context.avoidFrame,
                    orientation: .horizontal,
                    minimumVisibleFrame: minimumVisibleFrame
                ) else {
                    return nil
                }
                adjusted = clipped
            }
        }

        return adjusted
    }

    private static func adjustedFrameForManagedContext(
        _ separator: ZoneLayout.Separator,
        frame: CGRect,
        context: ZoneResizeHandleAvoidanceContext,
        minimumVisibleFrame: CGRect?
    ) -> CGRect? {
        // Managed windows in any tiling zone should avoid every separator.
        guard let clipped = clipSeparatorFrame(
            frame,
            avoiding: context.avoidFrame,
            orientation: separator.orientation,
            minimumVisibleFrame: minimumVisibleFrame
        ) else {
            return nil
        }
        return clipped
    }

    /// Returns the adjusted frame for a separator, or `nil` if it should be hidden.
    static func adjustedSeparatorFrame(
        _ separator: ZoneLayout.Separator,
        activeFitContext: ZoneResizeHandleAvoidanceContext?,
        managedContexts: [ZoneResizeHandleAvoidanceContext] = [],
        floatingZoneContext: ZoneResizeHandleFloatingZoneContext? = nil,
        pinnedContext: ZoneResizeHandlePinnedContext? = nil
    ) -> CGRect? {
        var frame = separator.frame.standardized
        let minimumVisibleFrame = pinnedContext?.minimumVisibleFrame

        // Floating-zone floating window: hide overlapping bars in normal mode;
        // when pinned, shrink them while preserving the placeholder minimum.
        if let floatingZoneContext,
           frame.intersects(floatingZoneContext.avoidFrame) {
            guard let minimumVisibleFrame else {
                return nil
            }
            guard let adjusted = clipSeparatorFrame(
                frame,
                avoiding: floatingZoneContext.avoidFrame,
                orientation: separator.orientation,
                minimumVisibleFrame: minimumVisibleFrame
            ) else {
                return nil
            }
            frame = adjusted
        }

        if let activeFitContext {
            guard let adjusted = adjustedFrameForActiveFitContext(
                separator,
                frame: frame,
                context: activeFitContext,
                minimumVisibleFrame: minimumVisibleFrame
            ) else {
                return nil
            }
            frame = adjusted
        }

        for managedContext in managedContexts {
            guard let adjusted = adjustedFrameForManagedContext(
                separator,
                frame: frame,
                context: managedContext,
                minimumVisibleFrame: minimumVisibleFrame
            ) else {
                return nil
            }
            frame = adjusted
        }

        return frame
    }
}
