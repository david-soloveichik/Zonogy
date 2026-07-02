import Foundation
import AppKit

/// Computes zone frame rectangles and separator geometry from each zone's side assignment.
///
/// Input is the ordered list of zone sides (element i is zone i+1's side). A side with one zone
/// gives it the full column height; a side with two stacks them (lower index on top); a side with
/// no zones cedes the full screen width to the other. Ratio state (column split and each side's
/// top-zone height) persists across topology changes.
struct ZoneLayout {
    enum SeparatorOrientation {
        case vertical
        case horizontal
    }

    /// Stable identity of a separator across layouts: the single vertical bar between the
    /// two columns, or a horizontal bar between the stacked zones of one side.
    enum SeparatorIdentity: Hashable {
        case vertical
        case horizontal(ZoneSide)

        var orientation: SeparatorOrientation {
            switch self {
            case .vertical:
                return .vertical
            case .horizontal:
                return .horizontal
            }
        }

        var logLabel: String {
            switch self {
            case .vertical:
                return "v"
            case .horizontal(let side):
                return "h-\(side.rawValue)"
            }
        }
    }

    struct Separator {
        let id: SeparatorIdentity
        let frame: CGRect

        var orientation: SeparatorOrientation {
            id.orientation
        }
    }

    /// Width fraction of the left column when both columns hold zones.
    private(set) var leftWidthRatio: CGFloat = 0.5
    /// Height fraction of the top zone within each side's two-zone stack.
    private(set) var topHeightRatios: [ZoneSide: CGFloat] = [.left: 0.5, .right: 0.5]

    static let minWidthRatio: CGFloat = 0.1
    static let minHeightRatio: CGFloat = 0.1
    private let marginSize: CGFloat = 8.0

    /// Computes frames for zones with the given sides using default ratios.
    /// - Returns: Array of frames, indexed from 0 (zone 1 is at index 0)
    static func computeFrames(sides: [ZoneSide], screenFrame: CGRect) -> [CGRect] {
        let layout = ZoneLayout()
        return layout.frames(sides: sides, screenFrame: screenFrame)
    }

    /// Computes frames based on the current ratio state.
    /// `sides[i]` is the side of zone i+1; frames are returned in the same order.
    func frames(sides: [ZoneSide], screenFrame: CGRect) -> [CGRect] {
        guard sides.count > 1 else {
            return [screenFrame]
        }

        let columnRects = columnRects(sides: sides, screenFrame: screenFrame)
        var stackPosition: [ZoneSide: Int] = [:]
        var sideCounts: [ZoneSide: Int] = [:]
        for side in sides {
            sideCounts[side, default: 0] += 1
        }

        return sides.map { side in
            let column = columnRects[side] ?? screenFrame
            let position = stackPosition[side, default: 0]
            stackPosition[side] = position + 1
            return zoneRect(
                in: column,
                stackCount: sideCounts[side] ?? 1,
                position: position,
                side: side
            )
        }
    }

    /// Splits the screen into per-side column rectangles. A side without zones gets a
    /// zero-width column at its screen edge and the other side spans the full width.
    private func columnRects(sides: [ZoneSide], screenFrame: CGRect) -> [ZoneSide: CGRect] {
        let hasLeft = sides.contains(.left)
        let hasRight = sides.contains(.right)

        guard hasLeft, hasRight else {
            let full = screenFrame
            let emptyLeft = CGRect(x: screenFrame.minX, y: screenFrame.minY, width: 0, height: screenFrame.height)
            let emptyRight = CGRect(x: screenFrame.maxX, y: screenFrame.minY, width: 0, height: screenFrame.height)
            return [
                .left: hasLeft ? full : emptyLeft,
                .right: hasRight ? full : emptyRight
            ]
        }

        let leftRatio = clampWidthRatio(leftWidthRatio)
        let leftWidth = (screenFrame.width * leftRatio).rounded()
        let leftRect = CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: leftWidth,
            height: screenFrame.height
        )
        let rightOriginX = (screenFrame.minX + leftWidth).rounded()
        let rightRect = CGRect(
            x: rightOriginX,
            y: screenFrame.minY,
            width: max((screenFrame.maxX - rightOriginX).rounded(), 0),
            height: screenFrame.height
        )
        return [.left: leftRect, .right: rightRect]
    }

    /// Frame of the zone at `position` (0 = top) within a column stacking `stackCount` zones.
    private func zoneRect(in column: CGRect, stackCount: Int, position: Int, side: ZoneSide) -> CGRect {
        guard stackCount > 1 else {
            return column
        }

        let topRatio = clampHeightRatio(topHeightRatios[side] ?? 0.5)
        let topHeight = (column.height * topRatio).rounded()
        if position == 0 {
            return CGRect(x: column.minX, y: column.minY, width: column.width, height: topHeight)
        }
        return CGRect(
            x: column.minX,
            y: (column.minY + topHeight).rounded(),
            width: column.width,
            height: max((column.height - topHeight).rounded(), 0)
        )
    }

    func separators(sides: [ZoneSide], screenFrame: CGRect) -> [Separator] {
        guard sides.count > 1 else {
            return []
        }

        var result: [Separator] = []
        let columns = columnRects(sides: sides, screenFrame: screenFrame)
        let hasBothColumns = sides.contains(.left) && sides.contains(.right)

        if hasBothColumns, let left = columns[.left] {
            let rect = CGRect(
                x: left.maxX - marginSize / 2,
                y: screenFrame.minY,
                width: marginSize,
                height: screenFrame.height
            )
            result.append(Separator(id: .vertical, frame: rect))
        }

        for side in ZoneSide.allCases {
            guard sides.filter({ $0 == side }).count == 2,
                  let column = columns[side] else {
                continue
            }
            let topRatio = clampHeightRatio(topHeightRatios[side] ?? 0.5)
            let boundaryY = (column.minY + (column.height * topRatio).rounded()).rounded()
            let rect = CGRect(
                x: column.minX,
                y: boundaryY - marginSize / 2,
                width: column.width,
                height: marginSize
            )
            result.append(Separator(id: .horizontal(side), frame: rect))
        }

        return result
    }

    /// Adjusts layout ratios after the specified zone has been resized to `newFrame`.
    mutating func resize(zoneIndex: Int, sides: [ZoneSide], screenFrame: CGRect, to newFrame: CGRect) {
        guard screenFrame.width > 0, screenFrame.height > 0,
              zoneIndex >= 1, zoneIndex <= sides.count else {
            return
        }

        let side = sides[zoneIndex - 1]
        let sanitizedWidth = max(0, min(newFrame.width, screenFrame.width))
        let sanitizedHeight = max(0, min(newFrame.height, screenFrame.height))

        if sides.contains(side.opposite) {
            let widthRatio = sanitizedWidth / screenFrame.width
            leftWidthRatio = clampWidthRatio(side == .left ? widthRatio : 1 - widthRatio)
        }

        if sides.filter({ $0 == side }).count == 2 {
            let isTop = sides.prefix(zoneIndex - 1).filter { $0 == side }.isEmpty
            let heightRatio = sanitizedHeight / screenFrame.height
            topHeightRatios[side] = clampHeightRatio(isTop ? heightRatio : 1 - heightRatio)
        }
    }

    mutating func resizeBySeparator(id: SeparatorIdentity, delta: CGFloat, screenFrame: CGRect) {
        guard screenFrame.width > 0, screenFrame.height > 0 else {
            return
        }

        switch id {
        case .vertical:
            let currentLeftWidth = screenFrame.width * leftWidthRatio
            leftWidthRatio = clampWidthRatio((currentLeftWidth + delta) / screenFrame.width)
        case .horizontal(let side):
            let currentTopRatio = topHeightRatios[side] ?? 0.5
            let currentTopHeight = screenFrame.height * currentTopRatio
            topHeightRatios[side] = clampHeightRatio((currentTopHeight + delta) / screenFrame.height)
        }
    }

    private func clampWidthRatio(_ ratio: CGFloat) -> CGFloat {
        let minRatio = Self.minWidthRatio
        let maxRatio = 1 - Self.minWidthRatio
        guard maxRatio > minRatio else {
            return 0.5
        }
        return min(max(ratio, minRatio), maxRatio)
    }

    private func clampHeightRatio(_ ratio: CGFloat) -> CGFloat {
        let minRatio = Self.minHeightRatio
        let maxRatio = 1 - Self.minHeightRatio
        guard maxRatio > minRatio else {
            return 0.5
        }
        return min(max(ratio, minRatio), maxRatio)
    }
}
