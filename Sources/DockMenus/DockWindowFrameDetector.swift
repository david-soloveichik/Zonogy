import AppKit
import ApplicationServices

/// Detects the macOS Dock bar frame using multiple strategies (Accessibility + CGWindowList).
///
/// The returned frame is in global screen coordinates with y:0 at top-left (matches Accessibility coordinates).
struct DockWindowFrameDetector {
    struct Snapshot: Equatable {
        let frame: CGRect
        let isOnScreen: Bool
        let windowNumber: Int
        let layer: Int
        let alpha: CGFloat
    }

    static let dockBundleIdentifier = "com.apple.dock"

    func currentDockWindowSnapshot() -> Snapshot? {
        let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleIdentifier).first?.processIdentifier

        let accessibilityScreenBounds = activeScreenBounds()
        let hasScreenBounds = !accessibilityScreenBounds.isEmpty

        if let dockPid,
           let axHitTestSnapshot = axDockBarSnapshotFromHitTest(dockPid: dockPid, screenBounds: accessibilityScreenBounds) {
            return axHitTestSnapshot
        }

        if let dockPid,
           let axSnapshot = axDockBarSnapshot(dockPid: dockPid, screenBounds: accessibilityScreenBounds) {
            return axSnapshot
        }

        // Do not exclude desktop elements: the Dock itself is a desktop element on macOS and can be filtered out.
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var candidates: [DockCandidate] = []
        for windowInfo in windowList {
            guard matchesDockOwner(windowInfo: windowInfo, dockPid: dockPid),
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width > 0,
                  frame.height > 0 else {
                continue
            }

            let alpha = numericValue(windowInfo[kCGWindowAlpha as String]) ?? 1.0
            if alpha <= 0.01 {
                continue
            }

            let layer = (windowInfo[kCGWindowLayer as String] as? Int) ?? 0
            let windowNumber = (windowInfo[kCGWindowNumber as String] as? Int) ?? -1
            let isOnScreen = boolValue(windowInfo[kCGWindowIsOnscreen as String]) ?? false

            let thickness = min(frame.width, frame.height)
            let length = max(frame.width, frame.height)
            guard thickness >= 10,
                  thickness <= 400,
                  length >= 200 else {
                continue
            }

            let edgeDistance: CGFloat
            if hasScreenBounds {
                edgeDistance = closestEdgeDistance(frame: frame, screenBounds: accessibilityScreenBounds)
                guard edgeDistance.isFinite else {
                    continue
                }
            } else {
                edgeDistance = 0
            }

            let aspectRatio = length / max(1, thickness)
            guard aspectRatio >= 2.0 else {
                continue
            }

            if hasScreenBounds,
               let bestScreen = bestIntersectingBounds(frame: frame, screenBounds: accessibilityScreenBounds) {
                let screenArea = bestScreen.width * bestScreen.height
                let candidateArea = frame.width * frame.height
                if screenArea > 0, candidateArea / screenArea > 0.6 {
                    continue
                }
            }

            candidates.append(
                DockCandidate(
                    frame: frame,
                    isOnScreen: isOnScreen,
                    windowNumber: windowNumber,
                    layer: layer,
                    alpha: alpha,
                    edgeDistance: edgeDistance,
                    aspectRatio: aspectRatio
                )
            )
        }

        guard let best = selectBestCandidate(from: candidates) else {
            return nil
        }

        return Snapshot(
            frame: best.frame,
            isOnScreen: best.isOnScreen,
            windowNumber: best.windowNumber,
            layer: best.layer,
            alpha: best.alpha
        )
    }

    private func matchesDockOwner(windowInfo: [String: Any], dockPid: pid_t?) -> Bool {
        if let dockPid,
           let ownerPid = pidValue(windowInfo[kCGWindowOwnerPID as String]),
           ownerPid == dockPid {
            return true
        }

        if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String, ownerName == "Dock" {
            return true
        }

        return false
    }

    func activeScreenBounds() -> [CGRect] {
        func boundsFromNSScreen() -> [CGRect] {
            let primaryCocoaBounds = NSScreen.screens.first?.frame ?? .zero
            return NSScreen.screens.map {
                CoordinateConversion.cocoaToAccessibility(cocoaFrame: $0.frame, primaryScreenBounds: primaryCocoaBounds)
            }
        }

        if Thread.isMainThread {
            return boundsFromNSScreen()
        } else {
            return DispatchQueue.main.sync {
                boundsFromNSScreen()
            }
        }
    }

    func closestEdgeDistance(frame: CGRect, screenBounds: [CGRect]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for bounds in screenBounds {
            let intersection = frame.intersection(bounds)
            if intersection.isNull || intersection.isEmpty {
                continue
            }

            let distances: [CGFloat] = [
                abs(frame.minX - bounds.minX),
                abs(frame.maxX - bounds.maxX),
                abs(frame.minY - bounds.minY),
                abs(frame.maxY - bounds.maxY)
            ]
            if let candidate = distances.min(), candidate < best {
                best = candidate
            }
        }

        if best == .greatestFiniteMagnitude {
            return .infinity
        }
        return best
    }

    private func bestIntersectingBounds(frame: CGRect, screenBounds: [CGRect]) -> CGRect? {
        var bestBounds: CGRect?
        var bestArea: CGFloat = 0

        for bounds in screenBounds {
            let intersection = frame.intersection(bounds)
            if intersection.isNull || intersection.isEmpty {
                continue
            }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestBounds = bounds
            }
        }

        return bestBounds
    }

    private struct DockCandidate {
        let frame: CGRect
        let isOnScreen: Bool
        let windowNumber: Int
        let layer: Int
        let alpha: CGFloat
        let edgeDistance: CGFloat
        let aspectRatio: CGFloat
    }

    private func selectBestCandidate(from candidates: [DockCandidate]) -> DockCandidate? {
        candidates.max(by: { score(candidate: $0) < score(candidate: $1) })
    }

    private func score(candidate: DockCandidate) -> Double {
        let thickness = Double(min(candidate.frame.width, candidate.frame.height))
        let length = Double(max(candidate.frame.width, candidate.frame.height))

        let onScreenBonus = candidate.isOnScreen ? 1_000.0 : 0.0
        let aspectScore = Double(candidate.aspectRatio) * 1_000_000.0
        let edgeScore = -Double(candidate.edgeDistance) * 1_000.0
        let thicknessPenalty = -thickness * 10_000.0
        let lengthScore = length * 100.0
        let layerPenalty = -Double(abs(candidate.layer - Int(CGWindowLevelForKey(.dockWindow)))) * 100.0

        return onScreenBonus + aspectScore + edgeScore + thicknessPenalty + lengthScore + layerPenalty
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private func numericValue(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let number = value as? NSNumber {
            return CGFloat(number.doubleValue)
        }
        return nil
    }

    private func pidValue(_ value: Any?) -> pid_t? {
        if let value = value as? pid_t {
            return value
        }
        if let value = value as? Int32 {
            return value
        }
        if let value = value as? Int {
            return pid_t(value)
        }
        if let number = value as? NSNumber {
            return number.int32Value
        }
        return nil
    }
}
