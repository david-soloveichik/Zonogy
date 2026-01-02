import AppKit
import ApplicationServices

/// Accessibility-backed helpers for locating the Dock bar frame (including auto-hide scenarios).
extension DockWindowFrameDetector {
    func axDockBarSnapshotFromHitTest(dockPid: pid_t, screenBounds: [CGRect]) -> Snapshot? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        guard let mousePoint = mouseLocationInAccessibilityCoordinates() else {
            return nil
        }

        guard let screen = bestScreenBounds(for: mousePoint, screenBounds: screenBounds) else {
            return nil
        }

        let probePoints = hitTestProbePoints(mousePoint: mousePoint, screenBounds: screen)
        let systemWide = AXUIElementCreateSystemWide()

        var candidates: [DockAXCandidate] = []
        candidates.reserveCapacity(16)

        for point in probePoints {
            var element: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
            guard status == .success, let element else {
                continue
            }

            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard pid == dockPid else {
                continue
            }

            candidates.append(contentsOf: axDockBarCandidates(from: element, screenBounds: screenBounds))
        }

        guard let best = candidates.max(by: { axScore(candidate: $0) < axScore(candidate: $1) }) else {
            return nil
        }

        return Snapshot(
            frame: best.frame,
            isOnScreen: true,
            windowNumber: -3,
            layer: Int(CGWindowLevelForKey(.dockWindow)),
            alpha: 1.0
        )
    }

    func axDockBarSnapshot(dockPid: pid_t, screenBounds: [CGRect]) -> Snapshot? {
        let appElement = AXUIElementCreateApplication(dockPid)
        var windowsValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard status == .success, let windowsValue else {
            return nil
        }

        let anyArray: [Any]
        if let array = windowsValue as? [Any] {
            anyArray = array
        } else if let array = windowsValue as? NSArray {
            anyArray = array.compactMap { $0 }
        } else {
            return nil
        }

        let windows: [AXUIElement] = anyArray.compactMap { item in
            let cf = item as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(cf, to: AXUIElement.self)
        }
        guard !windows.isEmpty else {
            return nil
        }

        var candidates: [DockAXCandidate] = []
        candidates.reserveCapacity(windows.count)

        for window in windows {
            guard let frame = axFrame(element: window),
                  frame.width > 0,
                  frame.height > 0 else {
                continue
            }

            let thickness = min(frame.width, frame.height)
            let length = max(frame.width, frame.height)

            guard thickness >= 10,
                  thickness <= 400,
                  length >= 200 else {
                continue
            }

            let aspectRatio = length / max(1, thickness)
            guard aspectRatio >= 2.0 else {
                continue
            }

            let edgeDistance = closestEdgeDistance(frame: frame, screenBounds: screenBounds)
            if edgeDistance.isFinite, edgeDistance > 40 {
                continue
            }

            let visibleRatio = bestIntersectionRatio(frame: frame, screenBounds: screenBounds)
            guard visibleRatio >= 0.3 else {
                continue
            }

            candidates.append(DockAXCandidate(
                frame: frame,
                edgeDistance: edgeDistance.isFinite ? edgeDistance : 0,
                aspectRatio: aspectRatio,
                thickness: thickness,
                visibleRatio: visibleRatio
            ))
        }

        guard let best = candidates.max(by: { axScore(candidate: $0) < axScore(candidate: $1) }) else {
            return nil
        }

        return Snapshot(
            frame: best.frame,
            isOnScreen: true,
            windowNumber: -2,
            layer: Int(CGWindowLevelForKey(.dockWindow)),
            alpha: 1.0
        )
    }

    // MARK: - Hit testing and candidate extraction

    private struct NearestEdge {
        let name: String
        let distance: CGFloat
    }

    private enum DockEdge {
        case bottom
        case left
        case right

        var name: String {
            switch self {
            case .bottom: return "bottom"
            case .left: return "left"
            case .right: return "right"
            }
        }
    }

    private func nearestDockEdge(point: CGPoint, in bounds: CGRect) -> NearestEdge {
        let left = abs(point.x - bounds.minX)
        let right = abs(bounds.maxX - point.x)
        let bottom = abs(bounds.maxY - point.y)

        let best: (DockEdge, CGFloat)
        if bottom <= left && bottom <= right {
            best = (.bottom, bottom)
        } else if left <= right {
            best = (.left, left)
        } else {
            best = (.right, right)
        }

        return NearestEdge(name: best.0.name, distance: best.1)
    }

    private func hitTestProbePoints(mousePoint: CGPoint, screenBounds: CGRect) -> [CGPoint] {
        struct Key: Hashable {
            let x: Int
            let y: Int
        }

        func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
            Swift.max(min, Swift.min(max, value))
        }

        func addPoint(_ point: CGPoint, to points: inout [CGPoint], seen: inout Set<Key>) {
            let rounded = CGPoint(x: round(point.x), y: round(point.y))
            let key = Key(x: Int(rounded.x), y: Int(rounded.y))
            guard !seen.contains(key) else { return }
            seen.insert(key)
            points.append(rounded)
        }

        var points: [CGPoint] = []
        var seen: Set<Key> = []

        addPoint(mousePoint, to: &points, seen: &seen)

        let nearest = nearestDockEdge(point: mousePoint, in: screenBounds)
        guard nearest.distance <= 140 else {
            return points
        }

        let inset: CGFloat = 2
        let fractions: [CGFloat] = [0.1, 0.3, 0.5, 0.7, 0.9]

        let minX = screenBounds.minX
        let maxX = screenBounds.maxX
        let minY = screenBounds.minY
        let maxY = screenBounds.maxY

        if nearest.name == DockEdge.bottom.name {
            let y = clamp(maxY - inset, min: minY + inset, max: maxY - inset)
            for fraction in fractions {
                let x = minX + screenBounds.width * fraction
                addPoint(CGPoint(x: x, y: y), to: &points, seen: &seen)
            }
            addPoint(CGPoint(x: mousePoint.x, y: y), to: &points, seen: &seen)
        } else if nearest.name == DockEdge.left.name {
            let x = clamp(minX + inset, min: minX + inset, max: maxX - inset)
            for fraction in fractions {
                let y = minY + screenBounds.height * fraction
                addPoint(CGPoint(x: x, y: y), to: &points, seen: &seen)
            }
            addPoint(CGPoint(x: x, y: mousePoint.y), to: &points, seen: &seen)
        } else {
            let x = clamp(maxX - inset, min: minX + inset, max: maxX - inset)
            for fraction in fractions {
                let y = minY + screenBounds.height * fraction
                addPoint(CGPoint(x: x, y: y), to: &points, seen: &seen)
            }
            addPoint(CGPoint(x: x, y: mousePoint.y), to: &points, seen: &seen)
        }

        return points
    }

    private func axDockBarCandidates(from leafElement: AXUIElement, screenBounds: [CGRect]) -> [DockAXCandidate] {
        var candidates: [DockAXCandidate] = []
        candidates.reserveCapacity(12)

        var element: AXUIElement? = leafElement
        var depth = 0

        while let current = element, depth < 40 {
            depth += 1

            if let frame = axFrame(element: current) {
                let thickness = min(frame.width, frame.height)
                let length = max(frame.width, frame.height)

                if thickness >= 10, thickness <= 400, length >= 200 {
                    let aspectRatio = length / max(1, thickness)
                    if aspectRatio >= 2.0 {
                        let edgeDistance = closestEdgeDistance(frame: frame, screenBounds: screenBounds)
                        if !edgeDistance.isFinite || edgeDistance <= 40 {
                            let visibleRatio = bestIntersectionRatio(frame: frame, screenBounds: screenBounds)
                            if visibleRatio >= 0.3 {
                                candidates.append(DockAXCandidate(
                                    frame: frame,
                                    edgeDistance: edgeDistance.isFinite ? edgeDistance : 0,
                                    aspectRatio: aspectRatio,
                                    thickness: thickness,
                                    visibleRatio: visibleRatio
                                ))
                            }
                        }
                    }
                }
            }

            element = axParent(of: current)
        }

        return candidates
    }

    // MARK: - AX helpers

    private struct DockAXCandidate {
        let frame: CGRect
        let edgeDistance: CGFloat
        let aspectRatio: CGFloat
        let thickness: CGFloat
        let visibleRatio: CGFloat
    }

    private func axScore(candidate: DockAXCandidate) -> Double {
        let aspectScore = Double(candidate.aspectRatio) * 1_000_000.0
        let edgeScore = -Double(candidate.edgeDistance) * 10_000.0
        let thicknessPenalty = -Double(candidate.thickness) * 5_000.0
        let visibilityScore = Double(candidate.visibleRatio) * 100_000.0
        return aspectScore + edgeScore + thicknessPenalty + visibilityScore
    }

    private func bestIntersectionRatio(frame: CGRect, screenBounds: [CGRect]) -> CGFloat {
        let area = frame.width * frame.height
        guard area > 0 else {
            return 0
        }

        var best: CGFloat = 0
        for bounds in screenBounds {
            let intersection = frame.intersection(bounds)
            if intersection.isNull || intersection.isEmpty {
                continue
            }
            let intersectionArea = intersection.width * intersection.height
            let ratio = intersectionArea / area
            if ratio > best {
                best = ratio
            }
        }
        return best
    }

    private func axFrame(element: AXUIElement) -> CGRect? {
        guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
              let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func axParent(of element: AXUIElement) -> AXUIElement? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &rawValue)
        guard status == .success, let rawValue else {
            return nil
        }
        guard CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func axStringAttribute(element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else {
            return nil
        }
        return value as? String
    }

    private func mouseLocationInAccessibilityCoordinates() -> CGPoint? {
        func readPoint() -> CGPoint? {
            let cocoaPoint = NSEvent.mouseLocation
            guard let primary = NSScreen.screens.first else {
                return nil
            }
            let primaryTop = primary.frame.origin.y + primary.frame.height
            return CGPoint(x: cocoaPoint.x, y: primaryTop - cocoaPoint.y)
        }

        if Thread.isMainThread {
            return readPoint()
        }
        return DispatchQueue.main.sync {
            readPoint()
        }
    }

    private func bestScreenBounds(for point: CGPoint, screenBounds: [CGRect]) -> CGRect? {
        if let containing = screenBounds.first(where: { $0.contains(point) }) {
            return containing
        }

        func distanceToRect(_ rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return sqrt(dx * dx + dy * dy)
        }

        return screenBounds.min(by: { distanceToRect($0) < distanceToRect($1) })
    }
}
