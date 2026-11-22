/// What "after every change" WinShot auto-save compares to notice that a display's arrangement
/// changed: everything a snapshot records except its thumbnail and active window. The occupancy is
/// also the snapshot's identity, so a change to the geometry alone refreshes the arrangement's
/// existing snapshot.
import CoreGraphics

struct WinShotArrangementState: Equatable {
    let occupancy: WinShotSnapshotOccupancySignature
    /// Tiling-zone frames, in zone order.
    let zoneFrames: [CGRect]
    /// The floating-zone window's frame as macOS last reported it (a frame Zonogy writes itself
    /// shows up once reported).
    let floatingWindowFrame: CGRect?
    /// Sticky Resize sizes of the display's tiled windows, by window id.
    let stickyResizeSizes: [Int: CGSize]
}
