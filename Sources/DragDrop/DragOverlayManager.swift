import AppKit

struct ZoneOverlayDescriptor {
    let key: ZoneKey
    let cocoaFrame: CGRect
    let isEmpty: Bool
}

final class DragOverlayManager {
    private final class OverlayWindow: NSWindow {
        init(frame: NSRect) {
            super.init(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            isReleasedWhenClosed = false
            ignoresMouseEvents = true
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            level = .floating
            collectionBehavior = [
                .canJoinAllSpaces,
                .transient,
                .fullScreenAuxiliary
            ]
        }
    }

    private final class OverlayView: NSView {
        var fillColor: NSColor = .clear {
            didSet {
                needsDisplay = true
            }
        }

        var borderColor: NSColor = .clear {
            didSet {
                needsDisplay = true
            }
        }

        override var isFlipped: Bool {
            true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard bounds.width > 0, bounds.height > 0 else {
                return
            }

            let insetRect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let path = NSBezierPath(roundedRect: insetRect, xRadius: 12, yRadius: 12)
            fillColor.setFill()
            path.fill()

            path.lineWidth = 2
            borderColor.setStroke()
            path.stroke()
        }
    }

    private final class OverlayHandle {
        let window: OverlayWindow
        let view: OverlayView
        var isEmpty: Bool

        init(window: OverlayWindow, view: OverlayView, isEmpty: Bool) {
            self.window = window
            self.view = view
            self.isEmpty = isEmpty
        }
    }

    private var overlays: [ZoneKey: OverlayHandle] = [:]
    private let occupiedBaseColor = NSColor.systemBlue.withAlphaComponent(0.14)
    private let emptyBaseColor = NSColor.systemBlue.withAlphaComponent(0.08)
    private let highlightColor = NSColor.systemBlue.withAlphaComponent(0.32)
    private let baseBorderColor = NSColor.systemBlue.withAlphaComponent(0.28)
    private let highlightBorderColor = NSColor.systemBlue.withAlphaComponent(0.55)

    func present(over descriptors: [ZoneOverlayDescriptor]) {
        var pendingRemoval = Set(overlays.keys)

        for descriptor in descriptors {
            let frame = descriptor.cocoaFrame.standardized

            if let handle = overlays[descriptor.key] {
                handle.window.setFrame(frame, display: true)
                handle.view.setFrameSize(frame.size)
                handle.isEmpty = descriptor.isEmpty
                applyColors(handle: handle, highlighted: false)
                handle.window.orderFrontRegardless()
                pendingRemoval.remove(descriptor.key)
                continue
            }

            let window = OverlayWindow(frame: frame)
            let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.orderFrontRegardless()

            let handle = OverlayHandle(window: window, view: view, isEmpty: descriptor.isEmpty)
            overlays[descriptor.key] = handle
            applyColors(handle: handle, highlighted: false)
        }

        for key in pendingRemoval {
            if let handle = overlays.removeValue(forKey: key) {
                handle.window.close()
            }
        }
    }

    func updateHighlight(to highlightedKey: ZoneKey?) {
        for (key, handle) in overlays {
            applyColors(handle: handle, highlighted: key == highlightedKey)
        }
    }

    func tearDown() {
        for handle in overlays.values {
            handle.window.close()
        }
        overlays.removeAll()
    }

    private func applyColors(handle: OverlayHandle, highlighted: Bool) {
        let baseColor = handle.isEmpty ? emptyBaseColor : occupiedBaseColor
        handle.view.fillColor = highlighted ? highlightColor : baseColor
        handle.view.borderColor = highlighted ? highlightBorderColor : baseBorderColor
    }
}
