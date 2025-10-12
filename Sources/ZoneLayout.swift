import Foundation
import AppKit

/// Stateless helper for computing zone frame rectangles
struct ZoneLayout {
    /// Computes the frame rectangles for the specified number of zones
    /// - Parameters:
    ///   - zoneCount: The number of zones (1-3)
    ///   - screenFrame: The screen frame to divide
    /// - Returns: Array of frames, indexed from 0 (zone 1 is at index 0)
    static func computeFrames(zoneCount: Int, screenFrame: CGRect) -> [CGRect] {
        switch zoneCount {
        case 1:
            // 1 zone: full screen
            return [screenFrame]

        case 2:
            // 2 zones: split into left and right
            let halfWidth = screenFrame.width / 2
            let leftFrame = CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: halfWidth,
                height: screenFrame.height
            )
            let rightFrame = CGRect(
                x: screenFrame.minX + halfWidth,
                y: screenFrame.minY,
                width: halfWidth,
                height: screenFrame.height
            )
            return [leftFrame, rightFrame]

        case 3:
            // 3 zones: left, right/top, right/bottom
            let halfWidth = screenFrame.width / 2
            let halfHeight = screenFrame.height / 2

            let leftFrame = CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: halfWidth,
                height: screenFrame.height
            )
            let rightTopFrame = CGRect(
                x: screenFrame.minX + halfWidth,
                y: screenFrame.minY + halfHeight,
                width: halfWidth,
                height: halfHeight
            )
            let rightBottomFrame = CGRect(
                x: screenFrame.minX + halfWidth,
                y: screenFrame.minY,
                width: halfWidth,
                height: halfHeight
            )
            return [leftFrame, rightTopFrame, rightBottomFrame]

        default:
            Logger.debug("Invalid zone count: \(zoneCount), defaulting to 1 zone")
            return [screenFrame]
        }
    }
}
