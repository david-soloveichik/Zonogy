/// A view with a top-left origin, used as the document view of scrolling preference content so
/// short content sits at the top rather than against the bottom edge.
import AppKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
