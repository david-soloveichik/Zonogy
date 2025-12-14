/// Captures mouseDown events (including clickCount) to enable immediate selection without SwiftUI tap-gesture delays

import AppKit
import SwiftUI

struct MouseDownCaptureView: NSViewRepresentable {
    let onMouseDown: (Int) -> Void

    func makeNSView(context: Context) -> CaptureView {
        CaptureView(onMouseDown: onMouseDown)
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onMouseDown = onMouseDown
    }

    final class CaptureView: NSView {
        var onMouseDown: (Int) -> Void

        init(onMouseDown: @escaping (Int) -> Void) {
            self.onMouseDown = onMouseDown
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            onMouseDown(event.clickCount)
        }
    }
}
