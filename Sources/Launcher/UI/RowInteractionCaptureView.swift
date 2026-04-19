/// Shared row interaction surface for hover, click-on-mouse-up, and drag-threshold activation.

import AppKit
import SwiftUI

struct RowInteractionCaptureView: NSViewRepresentable {
    let onClick: () -> Void
    var onHover: ((Bool) -> Void)? = nil
    var onMouseMove: (() -> Void)? = nil
    var onDragStart: (() -> Void)? = nil
    var dragExclusionTrailingWidth: CGFloat = 0

    func makeNSView(context: Context) -> CaptureView {
        CaptureView(
            onClick: onClick,
            onHover: onHover,
            onMouseMove: onMouseMove,
            onDragStart: onDragStart,
            dragExclusionTrailingWidth: dragExclusionTrailingWidth
        )
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onClick = onClick
        nsView.onHover = onHover
        nsView.onMouseMove = onMouseMove
        nsView.onDragStart = onDragStart
        nsView.dragExclusionTrailingWidth = dragExclusionTrailingWidth
    }

    final class CaptureView: NSView {
        private enum Constants {
            static let dragThreshold: CGFloat = 8
        }

        var onClick: () -> Void
        var onHover: ((Bool) -> Void)?
        var onMouseMove: (() -> Void)?
        var onDragStart: (() -> Void)?
        var dragExclusionTrailingWidth: CGFloat
        private var trackingArea: NSTrackingArea?
        private var isMouseDown = false
        private var dragStarted = false
        private var mouseDownPoint: NSPoint?
        private var mouseDownAllowsDrag = false

        init(
            onClick: @escaping () -> Void,
            onHover: ((Bool) -> Void)?,
            onMouseMove: (() -> Void)?,
            onDragStart: (() -> Void)?,
            dragExclusionTrailingWidth: CGFloat
        ) {
            self.onClick = onClick
            self.onHover = onHover
            self.onMouseMove = onMouseMove
            self.onDragStart = onDragStart
            self.dragExclusionTrailingWidth = dragExclusionTrailingWidth
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
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(newArea)
            trackingArea = newArea
        }

        override func mouseMoved(with event: NSEvent) {
            onMouseMove?()
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
            dragStarted = false
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            mouseDownAllowsDrag = shouldAllowDrag(from: mouseDownPoint)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isMouseDown,
                  !dragStarted,
                  mouseDownAllowsDrag,
                  onDragStart != nil,
                  let mouseDownPoint else {
                return
            }

            let location = convert(event.locationInWindow, from: nil)
            let dx = location.x - mouseDownPoint.x
            let dy = location.y - mouseDownPoint.y
            if hypot(dx, dy) >= Constants.dragThreshold {
                dragStarted = true
                onDragStart?()
            }
        }

        override func mouseUp(with event: NSEvent) {
            // Only trigger if mouse is still inside the view (cancel by drag away)
            if isMouseDown, !dragStarted {
                let location = convert(event.locationInWindow, from: nil)
                if bounds.contains(location) {
                    onClick()
                }
            }
            isMouseDown = false
            dragStarted = false
            mouseDownPoint = nil
            mouseDownAllowsDrag = false
        }

        private func shouldAllowDrag(from point: NSPoint?) -> Bool {
            guard dragExclusionTrailingWidth > 0,
                  let point else {
                return true
            }
            return point.x < bounds.maxX - dragExclusionTrailingWidth
        }
    }
}
