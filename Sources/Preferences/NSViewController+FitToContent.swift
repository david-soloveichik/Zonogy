/// Sizes a form-style Preferences tab to its content, so each such tab ends the same margin below its lowest control.
import AppKit

extension NSViewController {
    /// Lays out the view at its current width and sets the preferred height to reach `bottomMargin`
    /// below the lowest visible subview. Call again whenever the content's height can change.
    func fitPreferredContentSizeToContent(bottomMargin: CGFloat = 20) {
        view.layoutSubtreeIfNeeded()
        let bottoms = view.subviews.filter { !$0.isHidden }.map { subview in
            view.isFlipped ? subview.frame.maxY : view.bounds.height - subview.frame.minY
        }
        preferredContentSize = NSSize(width: view.bounds.width, height: ((bottoms.max() ?? 0) + bottomMargin).rounded(.up))
    }
}
