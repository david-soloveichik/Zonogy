import AppKit
import ApplicationServices

/// Detects the macOS Dock bar frame using Accessibility hit-testing.
///
/// The returned frame is in global screen coordinates with y:0 at top-left (matches Accessibility coordinates).
struct DockWindowFrameDetector {
    struct Snapshot: Equatable {
        let frame: CGRect
    }

    static let dockBundleIdentifier = "com.apple.dock"

    func currentDockWindowSnapshot() -> Snapshot? {
        guard let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleIdentifier).first?.processIdentifier else {
            return nil
        }

        let screenBounds = activeScreenBounds()
        return axDockBarSnapshotFromHitTest(dockPid: dockPid, screenBounds: screenBounds)
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
}
