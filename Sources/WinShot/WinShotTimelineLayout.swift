/// Pure geometry helper for mapping WinShot snapshot timestamps to timeline X positions.
import CoreGraphics
import Foundation

enum WinShotTimelineLayout {
    static func timelineXs(
        createdAt: [Date],
        tileCenterXs: [CGFloat],
        railStartX: CGFloat,
        railEndX: CGFloat
    ) -> [CGFloat] {
        guard !createdAt.isEmpty, createdAt.count == tileCenterXs.count else {
            return []
        }

        guard createdAt.count > 1 else {
            return [tileCenterXs[0]]
        }

        guard let newest = createdAt.max(),
              let oldest = createdAt.min() else {
            return tileCenterXs
        }

        let span = newest.timeIntervalSince(oldest)
        let width = railEndX - railStartX
        if span <= 0.000_001 || abs(width) <= 0.000_001 {
            return tileCenterXs
        }

        return createdAt.map { timestamp in
            let deltaFromNewest = newest.timeIntervalSince(timestamp)
            let ratio = min(max(deltaFromNewest / span, 0), 1)
            return railStartX + (CGFloat(ratio) * width)
        }
    }
}
