import Foundation
import AppKit

/// Represents a visual placeholder window for an empty tiling zone.
/// Unlike ManagedWindow, placeholders have no windowId - they are owned directly by zones.
final class PlaceholderWindow {
    /// The underlying AppKit panel (non-activating, frameless).
    let panel: PlaceholderPanel

    /// Screen this placeholder is currently displayed on.
    var screenDisplayId: CGDirectDisplayID

    /// Zone index this placeholder represents (1-based).
    var zoneIndex: Int

    /// The content view for this placeholder (provides UI updates).
    private var contentView: PlaceholderContentView? {
        panel.contentView as? PlaceholderContentView
    }

    init(panel: PlaceholderPanel, screenDisplayId: CGDirectDisplayID, zoneIndex: Int) {
        self.panel = panel
        self.screenDisplayId = screenDisplayId
        self.zoneIndex = zoneIndex
    }

    /// The current frame of the placeholder in Cocoa coordinates.
    var frame: CGRect {
        panel.frame
    }

    /// Whether the placeholder is currently visible on screen.
    var isVisible: Bool {
        panel.isVisible
    }

    /// Show the placeholder at the given frame (in screen coordinates).
    func show(at screenFrame: CGRect, on screen: ScreenDescriptor) {
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

    /// Reposition the placeholder to the given frame without changing visibility.
    func setFrame(_ screenFrame: CGRect, on screen: ScreenDescriptor) {
        let cocoaFrame = screen.screenToCocoa(screenFrame)
        panel.setFrame(cocoaFrame, display: true)
    }
}
