/// Draws the WinShot chooser timeline rail and orthogonal connectors to snapshot thumbnails.
import AppKit

final class WinShotTimelineView: NSView {
    struct Entry {
        let createdAt: Date
        let tileCenterX: CGFloat
    }

    static let verticalSpaceAboveThumbnails: CGFloat = 76

    private var entries: [Entry] = []
    private var timelineXs: [CGFloat] = []
    private var connectorLaneIndexes: [Int] = []
    private var selectedIndex: Int?
    private var hoveredIndex: Int?

    private static let railStrokeWidth: CGFloat = 2
    private static let connectorStrokeWidth: CGFloat = 1.5
    private static let selectedConnectorStrokeWidth: CGFloat = 2
    private static let pointRadius: CGFloat = 4
    private static let arrowHalfWidth: CGFloat = 4
    private static let arrowHeight: CGFloat = 6
    private static let singlePointRailHalfWidth: CGFloat = 14

    private static let railOffsetAboveThumbnails: CGFloat = 56
    private static let busOffsetAboveThumbnails: CGFloat = 24
    private static let arrowTipOffsetAboveThumbnails: CGFloat = 4
    private static let connectorLaneStep: CGFloat = 7
    private static let connectorLaneGap: CGFloat = 4
    private static let connectorMinClearanceFromRail: CGFloat = 4

    private static let railColor = NSColor(calibratedWhite: 1.0, alpha: 0.38)
    private static let connectorColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
    private static let pointColor = NSColor(calibratedWhite: 1.0, alpha: 0.92)
    private static let selectedColor = NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.85, alpha: 1.0)

    override var isOpaque: Bool {
        false
    }

    func configure(entries: [Entry]) {
        self.entries = entries
        recomputeTimelineXs()
        needsDisplay = true
    }

    func setSelectedIndex(_ index: Int) {
        let normalized: Int? = (index >= 0 && index < entries.count) ? index : nil
        guard selectedIndex != normalized else {
            return
        }
        selectedIndex = normalized
        needsDisplay = true
    }

    func setHoveredIndex(_ index: Int?) {
        let normalized: Int?
        if let index, index >= 0, index < entries.count {
            normalized = index
        } else {
            normalized = nil
        }

        guard hoveredIndex != normalized else {
            return
        }
        hoveredIndex = normalized
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeTimelineXs()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !entries.isEmpty else {
            return
        }

        let thumbnailTopY = WinShotThumbnailView.preferredSize.height
        let railY = thumbnailTopY + Self.railOffsetAboveThumbnails
        let baseBusY = thumbnailTopY + Self.busOffsetAboveThumbnails
        let arrowTipY = thumbnailTopY + Self.arrowTipOffsetAboveThumbnails
        let arrowBaseY = arrowTipY + Self.arrowHeight

        drawRail(y: railY)

        for index in entries.indices {
            let timelineX = timelineXs[index]
            let tileX = entries[index].tileCenterX
            let lane = laneIndex(for: index)
            let busY = baseBusY + (CGFloat(lane) * Self.connectorLaneStep)
            let isSelected = (index == selectedIndex)
            let isHovered = (index == hoveredIndex)
            let isHighlighted = isSelected || isHovered
            drawConnector(
                timelineX: timelineX,
                tileX: tileX,
                railY: railY,
                busY: busY,
                arrowBaseY: arrowBaseY,
                arrowTipY: arrowTipY,
                isSelected: isSelected,
                isHighlighted: isHighlighted
            )
        }

        for index in entries.indices {
            let timelineX = timelineXs[index]
            let isSelected = (index == selectedIndex)
            let isHovered = (index == hoveredIndex)
            drawPoint(x: timelineX, y: railY, isHighlighted: isSelected || isHovered)
        }
    }

    private func recomputeTimelineXs() {
        guard !entries.isEmpty else {
            timelineXs = []
            connectorLaneIndexes = []
            return
        }

        let railStartX = entries.first?.tileCenterX ?? 0
        let railEndX = entries.last?.tileCenterX ?? railStartX
        let tileCenterXs = entries.map(\.tileCenterX)
        timelineXs = WinShotTimelineLayout.timelineXs(
            createdAt: entries.map(\.createdAt),
            tileCenterXs: tileCenterXs,
            railStartX: railStartX,
            railEndX: railEndX
        )
        connectorLaneIndexes = WinShotTimelineConnectorRouting.laneIndexes(
            timelineXs: timelineXs,
            tileCenterXs: tileCenterXs,
            gap: Self.connectorLaneGap,
            maxLanes: maxAvailableLaneCount()
        )
    }

    private func laneIndex(for entryIndex: Int) -> Int {
        guard entryIndex >= 0, entryIndex < connectorLaneIndexes.count else {
            return 0
        }
        return connectorLaneIndexes[entryIndex]
    }

    private func maxAvailableLaneCount() -> Int {
        let thumbnailTopY = WinShotThumbnailView.preferredSize.height
        let railY = thumbnailTopY + Self.railOffsetAboveThumbnails
        let baseBusY = thumbnailTopY + Self.busOffsetAboveThumbnails
        let maxBusY = railY - Self.connectorMinClearanceFromRail

        guard maxBusY > baseBusY else {
            return 1
        }

        let laneCount = Int((maxBusY - baseBusY) / Self.connectorLaneStep) + 1
        return max(1, laneCount)
    }

    private func drawRail(y: CGFloat) {
        let railStartX: CGFloat
        let railEndX: CGFloat

        if entries.count == 1, let centerX = entries.first?.tileCenterX {
            railStartX = centerX - Self.singlePointRailHalfWidth
            railEndX = centerX + Self.singlePointRailHalfWidth
        } else {
            railStartX = entries.first?.tileCenterX ?? 0
            railEndX = entries.last?.tileCenterX ?? railStartX
        }

        let railPath = NSBezierPath()
        railPath.move(to: NSPoint(x: railStartX, y: y))
        railPath.line(to: NSPoint(x: railEndX, y: y))
        railPath.lineWidth = Self.railStrokeWidth
        Self.railColor.setStroke()
        railPath.stroke()
    }

    private func drawConnector(
        timelineX: CGFloat,
        tileX: CGFloat,
        railY: CGFloat,
        busY: CGFloat,
        arrowBaseY: CGFloat,
        arrowTipY: CGFloat,
        isSelected: Bool,
        isHighlighted: Bool
    ) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: timelineX, y: railY))
        path.line(to: NSPoint(x: timelineX, y: busY))
        path.line(to: NSPoint(x: tileX, y: busY))
        path.line(to: NSPoint(x: tileX, y: arrowBaseY))
        if isSelected {
            path.lineWidth = Self.selectedConnectorStrokeWidth
        } else if isHighlighted {
            path.lineWidth = Self.selectedConnectorStrokeWidth
        } else {
            path.lineWidth = Self.connectorStrokeWidth
        }

        let strokeColor: NSColor
        if isSelected {
            strokeColor = Self.selectedColor.withAlphaComponent(0.95)
        } else if isHighlighted {
            strokeColor = Self.selectedColor.withAlphaComponent(0.78)
        } else {
            strokeColor = Self.connectorColor
        }
        strokeColor.setStroke()
        path.stroke()

        let arrowPath = NSBezierPath()
        arrowPath.move(to: NSPoint(x: tileX - Self.arrowHalfWidth, y: arrowBaseY))
        arrowPath.line(to: NSPoint(x: tileX + Self.arrowHalfWidth, y: arrowBaseY))
        arrowPath.line(to: NSPoint(x: tileX, y: arrowTipY))
        arrowPath.close()
        if isSelected {
            Self.selectedColor.setFill()
        } else if isHighlighted {
            Self.selectedColor.withAlphaComponent(0.85).setFill()
        } else {
            Self.connectorColor.setFill()
        }
        arrowPath.fill()
    }

    private func drawPoint(x: CGFloat, y: CGFloat, isHighlighted: Bool) {
        let radius = Self.pointRadius + (isHighlighted ? 1 : 0)
        let frame = NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
        let pointPath = NSBezierPath(ovalIn: frame)
        (isHighlighted ? Self.selectedColor : Self.pointColor).setFill()
        pointPath.fill()
    }
}
