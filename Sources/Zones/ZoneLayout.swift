import Foundation
import AppKit

/// Helper for computing and updating zone frame rectangles.
struct ZoneLayout {
    enum SeparatorOrientation {
        case vertical
        case horizontal
    }

    struct Separator {
        let index: Int
        let orientation: SeparatorOrientation
        let frame: CGRect
    }

    private(set) var leftWidthRatio: CGFloat = 0.5
    private(set) var rightTopHeightRatio: CGFloat = 0.5

    static let minWidthRatio: CGFloat = 0.1
    static let minHeightRatio: CGFloat = 0.1
    private let marginSize: CGFloat = 8.0

    /// Computes the frame rectangles for the specified number of zones using default ratios.
    /// - Parameters:
    ///   - zoneCount: The number of zones (1-3)
    ///   - screenFrame: The screen frame to divide
    /// - Returns: Array of frames, indexed from 0 (zone 1 is at index 0)
    static func computeFrames(zoneCount: Int, screenFrame: CGRect) -> [CGRect] {
        let layout = ZoneLayout()
        return layout.frames(for: zoneCount, screenFrame: screenFrame)
    }

    /// Computes frames based on the current ratio state.
    func frames(for zoneCount: Int, screenFrame: CGRect) -> [CGRect] {
        switch zoneCount {
        case 1:
            return [screenFrame]

        case 2:
            let leftRatio = clampWidthRatio(leftWidthRatio)
            let leftWidth = (screenFrame.width * leftRatio).rounded()
            let leftFrame = CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: leftWidth,
                height: screenFrame.height
            )
            let rightOriginX = (screenFrame.minX + leftWidth).rounded()
            let rightWidth = max((screenFrame.maxX - rightOriginX).rounded(), 0)
            let rightFrame = CGRect(
                x: rightOriginX,
                y: screenFrame.minY,
                width: rightWidth,
                height: screenFrame.height
            )
            return [leftFrame, rightFrame]

        case 3:
            let leftRatio = clampWidthRatio(leftWidthRatio)
            let leftWidth = (screenFrame.width * leftRatio).rounded()
            let leftFrame = CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: leftWidth,
                height: screenFrame.height
            )

            let rightOriginX = (screenFrame.minX + leftWidth).rounded()
            let rightWidth = max((screenFrame.maxX - rightOriginX).rounded(), 0)

            let topRatio = clampHeightRatio(rightTopHeightRatio)
            let topHeight = (screenFrame.height * topRatio).rounded()
            let bottomHeight = max((screenFrame.height - topHeight).rounded(), 0)

            let rightTopFrame = CGRect(
                x: rightOriginX,
                y: screenFrame.minY,
                width: rightWidth,
                height: topHeight
            )
            let rightBottomFrame = CGRect(
                x: rightOriginX,
                y: (screenFrame.minY + topHeight).rounded(),
                width: rightWidth,
                height: bottomHeight
            )
            return [leftFrame, rightTopFrame, rightBottomFrame]

        default:
            Logger.debug("Invalid zone count: \(zoneCount), defaulting to 1 zone")
            return [screenFrame]
        }
    }

    func separators(zoneCount: Int, screenFrame: CGRect) -> [Separator] {
        let frames = self.frames(for: zoneCount, screenFrame: screenFrame)
        
        if zoneCount == 2 {
            // Vertical separator between zone 1 and 2
            // Located at leftFrame.maxX
            let left = frames[0]
            let x = left.maxX
            let rect = CGRect(x: x - marginSize/2, y: screenFrame.minY, width: marginSize, height: screenFrame.height)
            return [Separator(index: 0, orientation: .vertical, frame: rect)]
        } else if zoneCount == 3 {
            // Vertical separator between 1 and 2/3
            let left = frames[0]
            let x = left.maxX
            let vRect = CGRect(x: x - marginSize/2, y: screenFrame.minY, width: marginSize, height: screenFrame.height)
            
            // Horizontal separator between 2 and 3
            let top = frames[1]
            let y = top.maxY
            let hRect = CGRect(x: top.minX, y: y - marginSize/2, width: top.width, height: marginSize)
            
            return [
                Separator(index: 0, orientation: .vertical, frame: vRect),
                Separator(index: 1, orientation: .horizontal, frame: hRect)
            ]
        }
        return []
    }

    /// Adjusts layout ratios after the specified zone has been resized.
    mutating func resize(zoneIndex: Int, zoneCount: Int, screenFrame: CGRect, to newFrame: CGRect) {
        guard screenFrame.width > 0, screenFrame.height > 0 else {
            return
        }

        let sanitizedWidth = max(0, min(newFrame.width, screenFrame.width))
        let sanitizedHeight = max(0, min(newFrame.height, screenFrame.height))

        switch zoneCount {
        case 2:
            switch zoneIndex {
            case 1:
                let ratio = sanitizedWidth / screenFrame.width
                leftWidthRatio = clampWidthRatio(ratio)
            case 2:
                let ratio = 1 - (sanitizedWidth / screenFrame.width)
                leftWidthRatio = clampWidthRatio(ratio)
            default:
                break
            }

        case 3:
            switch zoneIndex {
            case 1:
                let ratio = sanitizedWidth / screenFrame.width
                leftWidthRatio = clampWidthRatio(ratio)

            case 2:
                let widthRatio = 1 - (sanitizedWidth / screenFrame.width)
                leftWidthRatio = clampWidthRatio(widthRatio)

                let topRatio = sanitizedHeight / screenFrame.height
                rightTopHeightRatio = clampHeightRatio(topRatio)

            case 3:
                let widthRatio = 1 - (sanitizedWidth / screenFrame.width)
                leftWidthRatio = clampWidthRatio(widthRatio)

                let bottomRatio = sanitizedHeight / screenFrame.height
                let topRatio = 1 - bottomRatio
                rightTopHeightRatio = clampHeightRatio(topRatio)

            default:
                break
            }

        default:
            break
        }
    }

    mutating func resizeBySeparator(index: Int, delta: CGFloat, zoneCount: Int, screenFrame: CGRect) {
         if zoneCount == 2 || zoneCount == 3 {
             if index == 0 { // Vertical
                 let currentLeftWidth = screenFrame.width * leftWidthRatio
                 let newLeftWidth = currentLeftWidth + delta
                 leftWidthRatio = clampWidthRatio(newLeftWidth / screenFrame.width)
             }
         }
         if zoneCount == 3 {
             if index == 1 { // Horizontal
                 let currentTopHeight = screenFrame.height * rightTopHeightRatio
                 let newTopHeight = currentTopHeight + delta
                 rightTopHeightRatio = clampHeightRatio(newTopHeight / screenFrame.height)
             }
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