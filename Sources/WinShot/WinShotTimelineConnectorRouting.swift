/// Pure helper for assigning timeline connector lanes to avoid crossings when possible.
import CoreGraphics
import Foundation

enum WinShotTimelineConnectorRouting {
    static func laneIndexes(
        timelineXs: [CGFloat],
        tileCenterXs: [CGFloat],
        gap: CGFloat,
        maxLanes: Int
    ) -> [Int] {
        guard let connectors = makeConnectors(timelineXs: timelineXs, tileCenterXs: tileCenterXs),
              maxLanes > 0 else {
            return []
        }

        let connectorOrder = connectors.indices.sorted { lhs, rhs in
            let lhsSpan = connectors[lhs].endX - connectors[lhs].startX
            let rhsSpan = connectors[rhs].endX - connectors[rhs].startX
            if lhsSpan != rhsSpan {
                return lhsSpan > rhsSpan
            }
            return connectors[lhs].index < connectors[rhs].index
        }

        var assignmentInOrder = Array(repeating: 0, count: connectors.count)
        var bestAssignmentInOrder: [Int]?
        var bestScore: Score?

        search(
            connectors: connectors,
            connectorOrder: connectorOrder,
            gap: gap,
            maxLanes: maxLanes,
            position: 0,
            usedLaneCount: 0,
            currentCrossings: 0,
            currentOverlaps: 0,
            currentLaneSum: 0,
            assignmentInOrder: &assignmentInOrder,
            bestAssignmentInOrder: &bestAssignmentInOrder,
            bestScore: &bestScore
        )

        guard let bestAssignmentInOrder else {
            return Array(repeating: 0, count: connectors.count)
        }

        var byOriginalIndex = Array(repeating: 0, count: connectors.count)
        for (position, connectorIndex) in connectorOrder.enumerated() {
            byOriginalIndex[connectorIndex] = bestAssignmentInOrder[position]
        }
        return byOriginalIndex
    }

    /// Returns the number of geometric crossings and same-lane overlap penalties for a fixed assignment.
    static func score(
        timelineXs: [CGFloat],
        tileCenterXs: [CGFloat],
        laneIndexes: [Int],
        gap: CGFloat
    ) -> (crossings: Int, overlaps: Int)? {
        guard let connectors = makeConnectors(timelineXs: timelineXs, tileCenterXs: tileCenterXs),
              laneIndexes.count == connectors.count,
              laneIndexes.allSatisfy({ $0 >= 0 }) else {
            return nil
        }

        var crossings = 0
        var overlaps = 0
        for left in connectors.indices {
            for right in connectors.indices where right > left {
                let pair = pairCost(
                    first: connectors[left],
                    firstLane: laneIndexes[left],
                    second: connectors[right],
                    secondLane: laneIndexes[right],
                    gap: gap
                )
                crossings += pair.crossings
                overlaps += pair.overlaps
            }
        }
        return (crossings, overlaps)
    }

    private struct Connector {
        let index: Int
        let timelineX: CGFloat
        let tileX: CGFloat
        let startX: CGFloat
        let endX: CGFloat
    }

    private struct Score: Comparable {
        let crossings: Int
        let overlaps: Int
        let laneSum: Int

        static func < (lhs: Score, rhs: Score) -> Bool {
            if lhs.crossings != rhs.crossings {
                return lhs.crossings < rhs.crossings
            }
            if lhs.overlaps != rhs.overlaps {
                return lhs.overlaps < rhs.overlaps
            }
            return lhs.laneSum < rhs.laneSum
        }
    }

    private static func makeConnectors(timelineXs: [CGFloat], tileCenterXs: [CGFloat]) -> [Connector]? {
        guard !timelineXs.isEmpty, timelineXs.count == tileCenterXs.count else {
            return nil
        }
        return timelineXs.enumerated().map { index, timelineX in
            let tileX = tileCenterXs[index]
            return Connector(
                index: index,
                timelineX: timelineX,
                tileX: tileX,
                startX: min(timelineX, tileX),
                endX: max(timelineX, tileX)
            )
        }
    }

    private static func search(
        connectors: [Connector],
        connectorOrder: [Int],
        gap: CGFloat,
        maxLanes: Int,
        position: Int,
        usedLaneCount: Int,
        currentCrossings: Int,
        currentOverlaps: Int,
        currentLaneSum: Int,
        assignmentInOrder: inout [Int],
        bestAssignmentInOrder: inout [Int]?,
        bestScore: inout Score?
    ) {
        if position == connectorOrder.count {
            let score = Score(crossings: currentCrossings, overlaps: currentOverlaps, laneSum: currentLaneSum)
            if bestScore == nil || score < bestScore! {
                bestScore = score
                bestAssignmentInOrder = assignmentInOrder
            }
            return
        }

        let connectorIndex = connectorOrder[position]
        let connector = connectors[connectorIndex]
        let highestCandidateLane = min(usedLaneCount, maxLanes - 1)

        for lane in 0...highestCandidateLane {
            var addedCrossings = 0
            var addedOverlaps = 0

            for previousPosition in 0..<position {
                let previousConnectorIndex = connectorOrder[previousPosition]
                let previousConnector = connectors[previousConnectorIndex]
                let previousLane = assignmentInOrder[previousPosition]
                let pair = pairCost(
                    first: connector,
                    firstLane: lane,
                    second: previousConnector,
                    secondLane: previousLane,
                    gap: gap
                )
                addedCrossings += pair.crossings
                addedOverlaps += pair.overlaps
            }

            let nextCrossings = currentCrossings + addedCrossings
            let nextOverlaps = currentOverlaps + addedOverlaps
            let nextLaneSum = currentLaneSum + lane

            if let bestScore {
                if nextCrossings > bestScore.crossings {
                    continue
                }
                if nextCrossings == bestScore.crossings, nextOverlaps > bestScore.overlaps {
                    continue
                }
                if nextCrossings == bestScore.crossings,
                   nextOverlaps == bestScore.overlaps,
                   nextLaneSum > bestScore.laneSum {
                    continue
                }
            }

            assignmentInOrder[position] = lane
            let nextUsedLaneCount = max(usedLaneCount, lane + 1)
            search(
                connectors: connectors,
                connectorOrder: connectorOrder,
                gap: gap,
                maxLanes: maxLanes,
                position: position + 1,
                usedLaneCount: nextUsedLaneCount,
                currentCrossings: nextCrossings,
                currentOverlaps: nextOverlaps,
                currentLaneSum: nextLaneSum,
                assignmentInOrder: &assignmentInOrder,
                bestAssignmentInOrder: &bestAssignmentInOrder,
                bestScore: &bestScore
            )
        }
    }

    private static func pairCost(
        first: Connector,
        firstLane: Int,
        second: Connector,
        secondLane: Int,
        gap: CGFloat
    ) -> (crossings: Int, overlaps: Int) {
        var crossings = 0

        // Top-vertical(first) vs horizontal(second)
        if secondLane > firstLane,
           isStrictlyInside(first.timelineX, start: second.startX, end: second.endX) {
            crossings += 1
        }
        // Bottom-vertical(first) vs horizontal(second)
        if secondLane < firstLane,
           isStrictlyInside(first.tileX, start: second.startX, end: second.endX) {
            crossings += 1
        }

        // Top-vertical(second) vs horizontal(first)
        if firstLane > secondLane,
           isStrictlyInside(second.timelineX, start: first.startX, end: first.endX) {
            crossings += 1
        }
        // Bottom-vertical(second) vs horizontal(first)
        if firstLane < secondLane,
           isStrictlyInside(second.tileX, start: first.startX, end: first.endX) {
            crossings += 1
        }

        var overlaps = 0
        if firstLane == secondLane, intervalsConflict(firstStart: first.startX, firstEnd: first.endX, secondStart: second.startX, secondEnd: second.endX, gap: gap) {
            overlaps = 1
        }

        return (crossings, overlaps)
    }

    private static func intervalsConflict(
        firstStart: CGFloat,
        firstEnd: CGFloat,
        secondStart: CGFloat,
        secondEnd: CGFloat,
        gap: CGFloat
    ) -> Bool {
        let separated = (firstEnd + gap <= secondStart) || (secondEnd + gap <= firstStart)
        return !separated
    }

    private static func isStrictlyInside(_ x: CGFloat, start: CGFloat, end: CGFloat) -> Bool {
        let epsilon: CGFloat = 0.0001
        return x > (start + epsilon) && x < (end - epsilon)
    }
}
