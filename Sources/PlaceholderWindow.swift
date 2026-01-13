import Foundation
import AppKit

/// Represents a visual placeholder window for an empty tiling zone.
/// Unlike ManagedWindow, placeholders have no windowId and are managed internally by Zonogy.
final class PlaceholderWindow {
    /// The underlying AppKit panel (non-activating, frameless).
    private let panel: PlaceholderPanel

    /// Screen this placeholder is currently displayed on.
    private(set) var screenDisplayId: CGDirectDisplayID

    /// Zone index this placeholder represents (1-based).
    private(set) var zoneIndex: Int

    /// The content view for this placeholder (provides UI updates).
    private var contentView: PlaceholderContentView? {
        panel.contentView as? PlaceholderContentView
    }

    init(panel: PlaceholderPanel, screenDisplayId: CGDirectDisplayID, zoneIndex: Int) {
        self.panel = panel
        self.screenDisplayId = screenDisplayId
        self.zoneIndex = zoneIndex
    }

    /// Show the placeholder at the given frame (in screen coordinates).
    func show(at screenFrame: CGRect, on screen: ScreenDescriptor) {
        screenDisplayId = screen.displayId
        let cocoaFrame = screen.screenToCocoa(screenFrame)
        panel.setFrame(cocoaFrame, display: true)
        panel.orderFront(nil)
    }

    /// Hide the placeholder (order out without closing).
    func hide() {
        panel.orderOut(nil)
    }

    /// Close the placeholder window permanently.
    func close() {
        panel.close()
    }

    /// Update the placeholder's zone assignment (used during reuse).
    func update(screenId: CGDirectDisplayID, zoneIndex: Int) {
        self.screenDisplayId = screenId
        self.zoneIndex = zoneIndex
        contentView?.update(screenId: screenId, zoneIndex: zoneIndex)
    }
}
