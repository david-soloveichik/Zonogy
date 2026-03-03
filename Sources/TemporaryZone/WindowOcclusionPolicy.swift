import CoreGraphics

/// Pure, deterministic occlusion policy for deciding whether a target window is visually covered by
/// any in-front occluder windows (given z-order and frames).
///
/// This logic is intentionally isolated so it can be guardrail-tested without relying on the
/// window server, Accessibility, or timing.
struct OcclusionWindow: Equatable {
    let cgWindowId: Int
    /// Frame in the same coordinate system for all windows (typically global accessibility coords).
    let frame: CGRect
}

enum WindowOcclusionPolicy {
    /// Returns true when any occluder window that is in front of `target` in the provided z-order
    /// intersects `target` by more than a tiny threshold (after applying an inset to ignore shadows).
    static func isOccluded(
        target: OcclusionWindow,
        occluders: [OcclusionWindow],
        zOrderFrontToBack: [Int],
        avoidanceInset: CGFloat = 6,
        minIntersectionDimension: CGFloat = 1
    ) -> Bool {
        guard !occluders.isEmpty else {
            return false
        }

        var zIndexByWindowId: [Int: Int] = [:]
        zIndexByWindowId.reserveCapacity(zOrderFrontToBack.count)
        for (index, windowId) in zOrderFrontToBack.enumerated() where zIndexByWindowId[windowId] == nil {
            zIndexByWindowId[windowId] = index
        }

        guard let targetIndex = zIndexByWindowId[target.cgWindowId] else {
            return false
        }

        let targetFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(target.frame, by: avoidanceInset)

        for occluder in occluders where occluder.cgWindowId != target.cgWindowId {
            guard let occluderIndex = zIndexByWindowId[occluder.cgWindowId],
                  occluderIndex < targetIndex else {
                continue
            }

            let occluderFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(occluder.frame, by: avoidanceInset)
            let intersection = targetFrame.intersection(occluderFrame)
            guard !intersection.isNull,
                  intersection.width > minIntersectionDimension,
                  intersection.height > minIntersectionDimension else {
                continue
            }
            return true
        }

        return false
    }
}
