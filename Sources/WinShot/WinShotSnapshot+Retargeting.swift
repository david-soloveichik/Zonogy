/// Maps a WinShot snapshot's geometry onto a display's visible bounds, so an arrangement captured on
/// one display can open on another (or on its own display after its visible bounds changed).
import CoreGraphics

extension WinShotSnapshot {
    /// A copy of this snapshot laid out for `screenId`, whose visible bounds are `destination`.
    ///
    /// The tiling arrangement scales proportionally from `layoutBounds` to `destination`: zone
    /// frames and Sticky Resize remembered sizes. The floating
    /// window keeps its size; its center lands at the same relative position and the window is nudged
    /// to stay within the visible bounds (shrunk only when it is larger than them). Identical visible
    /// bounds leave every frame untouched, so restoring on the capture display reproduces the
    /// arrangement exactly (a floating window that sat partly off-screen is not nudged back).
    func retargeted(to screenId: CGDirectDisplayID, layoutBounds destination: CGRect) -> WinShotSnapshot {
        let source = layoutBounds
        let isUnchanged = source == destination
            || source.width <= 0 || source.height <= 0 || destination.width <= 0 || destination.height <= 0
        let scaleX = isUnchanged ? 1 : destination.width / source.width
        let scaleY = isUnchanged ? 1 : destination.height / source.height

        func mapped(_ rect: CGRect) -> CGRect {
            guard !isUnchanged else { return rect }
            return CGRect(
                x: destination.minX + (rect.minX - source.minX) * scaleX,
                y: destination.minY + (rect.minY - source.minY) * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            )
        }

        func mappedFloating(_ frame: CGRect) -> CGRect {
            guard !isUnchanged else { return frame }
            let size = CGSize(
                width: min(frame.width, destination.width),
                height: min(frame.height, destination.height)
            )
            let relativeCenterX = (frame.midX - source.minX) / source.width
            let relativeCenterY = (frame.midY - source.minY) / source.height
            var origin = CGPoint(
                x: (destination.minX + relativeCenterX * destination.width - size.width / 2).rounded(),
                y: (destination.minY + relativeCenterY * destination.height - size.height / 2).rounded()
            )
            origin.x = max(destination.minX, min(origin.x, destination.maxX - size.width))
            origin.y = max(destination.minY, min(origin.y, destination.maxY - size.height))
            return CGRect(origin: origin, size: size)
        }

        return WinShotSnapshot(
            id: id,
            screenId: screenId,
            createdAt: createdAt,
            supersededAt: supersededAt,
            layoutBounds: isUnchanged ? source : destination,
            zoneCount: zoneCount,
            zoneFrames: zoneFrames.mapValues(mapped),
            rememberedTiledWindowSizesByZoneIndex: rememberedTiledWindowSizesByZoneIndex.mapValues {
                CGSize(width: $0.width * scaleX, height: $0.height * scaleY)
            },
            zoneAssignments: zoneAssignments,
            floatingZoneOccupant: floatingZoneOccupant,
            floatingZoneFrame: floatingZoneFrame.map(mappedFloating),
            activeWindowId: activeWindowId,
            thumbnail: thumbnail
        )
    }
}
