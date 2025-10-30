import Foundation
import AppKit

/// Helper for computing and updating zone frame rectangles.
struct ZoneLayout {
    private(set) var leftWidthRatio: CGFloat = 0.5
    private(set) var rightTopHeightRatio: CGFloat = 0.5

    private let minWidthRatio: CGFloat = 0.1
    private let minHeightRatio: CGFloat = 0.1

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
            let leftWidth = screenFrame.width * leftRatio
            let leftFrame = CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: leftWidth,
                height: screenFrame.height
            )
            let rightOriginX = leftFrame.maxX
            let rightWidth = max(screenFrame.maxX - rightOriginX, 0)
            let rightFrame = CGRect(
                x: rightOriginX,
                y: screenFrame.minY,
                width: rightWidth,
                height: screenFrame.height
            )
            return [leftFrame, rightFrame]

        case 3:
            let leftRatio = clampWidthRatio(leftWidthRatio)
            let leftWidth = screenFrame.width * leftRatio
            let leftFrame = CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: leftWidth,
                height: screenFrame.height
            )

            let rightOriginX = leftFrame.maxX
            let rightWidth = max(screenFrame.maxX - rightOriginX, 0)

            let topRatio = clampHeightRatio(rightTopHeightRatio)
            let topHeight = screenFrame.height * topRatio
            let bottomHeight = max(screenFrame.height - topHeight, 0)

            let rightTopFrame = CGRect(
                x: rightOriginX,
                y: screenFrame.minY,
                width: rightWidth,
                height: topHeight
            )
            let rightBottomFrame = CGRect(
                x: rightOriginX,
                y: screenFrame.minY + topHeight,
                width: rightWidth,
                height: bottomHeight
            )
            return [leftFrame, rightTopFrame, rightBottomFrame]

        default:
            Logger.debug("Invalid zone count: \(zoneCount), defaulting to 1 zone")
            return [screenFrame]
        }
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

    private func clampWidthRatio(_ ratio: CGFloat) -> CGFloat {
        let minRatio = minWidthRatio
        let maxRatio = 1 - minWidthRatio
        guard maxRatio > minRatio else {
            return 0.5
        }
        return min(max(ratio, minRatio), maxRatio)
    }

    private func clampHeightRatio(_ ratio: CGFloat) -> CGFloat {
        let minRatio = minHeightRatio
        let maxRatio = 1 - minHeightRatio
        guard maxRatio > minRatio else {
            return 0.5
        }
        return min(max(ratio, minRatio), maxRatio)
    }
}
