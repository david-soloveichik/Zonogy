/// Tweaks the underlying NSScrollView/NSScroller styling used by SwiftUI ScrollView

import AppKit
import SwiftUI

struct ScrollViewScrollerStyler: NSViewRepresentable {
    var scrollerStyle: NSScroller.Style = .overlay
    var knobStyle: NSScroller.KnobStyle = .light
    var controlSize: NSControl.ControlSize = .mini
    var alpha: CGFloat = 0.7

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = findNearestScrollView(from: nsView) else { return }
            applyStyle(to: scrollView)
        }
    }

    private func applyStyle(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = scrollerStyle
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false

        if let scroller = scrollView.verticalScroller {
            scroller.knobStyle = knobStyle
            scroller.controlSize = controlSize
            scroller.alphaValue = alpha
        }

        if let scroller = scrollView.horizontalScroller {
            scroller.knobStyle = knobStyle
            scroller.controlSize = controlSize
            scroller.alphaValue = alpha
        }
    }

    private func findNearestScrollView(from view: NSView) -> NSScrollView? {
        if let scrollView = view.enclosingScrollView {
            return scrollView
        }

        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            if let found = findScrollView(in: candidate) {
                return found
            }
            current = candidate.superview
        }

        if let windowRoot = view.window?.contentView, let found = findScrollView(in: windowRoot) {
            return found
        }

        return nil
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView {
                return scrollView
            }
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}
