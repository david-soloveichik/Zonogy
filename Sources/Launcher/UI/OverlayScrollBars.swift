/// Slim scroll bar for the Launcher's lists that floats over the rows and hides when idle, whatever the
/// system's "Show scroll bars" setting

import AppKit
import SwiftUI

/// Goes inside a ScrollView's content, with `.scrollIndicators(.never)` on the ScrollView. SwiftUI's own
/// scroll bar follows the system setting, and under Always it narrows the rows for a track that looks
/// heavy in the frosted panel. With `.never`, SwiftUI lays the rows out at full width, and this view then
/// turns on AppKit's overlay scroll bar, which floats over the rows instead of taking room.
struct OverlayScrollBars: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        OverlayScrollBarsView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class OverlayScrollBarsView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Deferred past SwiftUI's own scroll view setup, which applies `.never` later in this pass
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.hasVerticalScroller = true
            }
        }

        // Only here to reach the scroll view; clicks and scrolls pass through to the list.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
