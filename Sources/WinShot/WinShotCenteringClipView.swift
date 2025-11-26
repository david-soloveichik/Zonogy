/// Clip view that centers its document view when content is smaller than the visible area.
import AppKit

final class WinShotCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)

        guard let documentView = documentView else {
            return constrained
        }

        let docFrame = documentView.frame

        // Center horizontally when the document is narrower than the clip view.
        if docFrame.width < proposedBounds.width {
            constrained.origin.x = floor((proposedBounds.width - docFrame.width) / -2.0)
        }

        // Center vertically when the document is shorter than the clip view.
        if docFrame.height < proposedBounds.height {
            constrained.origin.y = floor((proposedBounds.height - docFrame.height) / -2.0)
        }

        return constrained
    }
}

