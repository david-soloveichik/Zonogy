/// Captures mouse click (mouseUp) and hover events for item activation and hover highlighting

import AppKit
import SwiftUI

struct MouseClickCaptureView: NSViewRepresentable {
    let onClick: () -> Void
    var onHover: ((Bool) -> Void)?

    func makeNSView(context: Context) -> CaptureView {
        CaptureView(onClick: onClick, onHover: onHover)
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onClick = onClick
        nsView.onHover = onHover
    }

    final class CaptureView: NSView {
        var onClick: () -> Void
        var onHover: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var isMouseDown = false

        init(onClick: @escaping () -> Void, onHover: ((Bool) -> Void)?) {
            self.onClick = onClick
            self.onHover = onHover
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let existingArea = trackingArea {
                removeTrackingArea(existingArea)
            }

            let newArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(newArea)
            trackingArea = newArea
        }

        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(false)
        }

        override func scrollWheel(with event: NSEvent) {
            // Forward scroll events to the next responder (the scroll view)
            nextResponder?.scrollWheel(with: event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            isMouseDown = true
        }

        override func mouseUp(with event: NSEvent) {
            // Only trigger if mouse is still inside the view (cancel by drag away)
            if isMouseDown {
                let location = convert(event.locationInWindow, from: nil)
                if bounds.contains(location) {
                    onClick()
                }
            }
            isMouseDown = false
        }
    }
}
