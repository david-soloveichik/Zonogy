import AppKit

struct ZoneIndicatorDescriptor {
    let key: ZoneKey
    let cocoaFrame: CGRect
    let isTargeted: Bool
}

protocol ZoneIndicatorManagerDelegate: AnyObject {
    func zoneIndicatorActivated(_ key: ZoneKey)
}

final class ZoneIndicatorManager {
    private final class IndicatorWindow: NSWindow {
        init(frame: NSRect) {
            super.init(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            isReleasedWhenClosed = false
            ignoresMouseEvents = false
            isOpaque = false
            hasShadow = false
            backgroundColor = .clear
            level = .floating
            collectionBehavior = [
                .canJoinAllSpaces,
                .transient,
                .fullScreenAuxiliary
            ]
        }

        override var canBecomeKey: Bool {
            false
        }

        override var canBecomeMain: Bool {
            false
        }
    }

    private final class IndicatorView: NSView {
        weak var delegate: ZoneIndicatorManagerDelegate?
        let key: ZoneKey
        var isTargeted: Bool {
            didSet {
                applyStyle()
            }
        }

        private let targetedColor = NSColor.systemBlue.withAlphaComponent(0.55)
        private let targetedBorder = NSColor.systemBlue.withAlphaComponent(0.75)
        private let untargetedColor = NSColor.systemBlue.withAlphaComponent(0.25)
        private let untargetedBorder = NSColor.systemBlue.withAlphaComponent(0.4)

        init(frame frameRect: NSRect, key: ZoneKey, targeted: Bool) {
            self.key = key
            self.isTargeted = targeted
            super.init(frame: frameRect)
            wantsLayer = true
            if #available(macOS 10.15, *) {
                layer?.cornerCurve = .continuous
            }
            applyStyle()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.height / 2
        }

        private func applyStyle() {
            guard let layer else {
                return
            }

            let background = isTargeted ? targetedColor : untargetedColor
            let border = isTargeted ? targetedBorder : untargetedBorder

            layer.backgroundColor = background.cgColor
            layer.borderColor = border.cgColor
            layer.borderWidth = 1.2
            layer.shadowColor = NSColor.systemBlue.withAlphaComponent(isTargeted ? 0.6 : 0.0).cgColor
            layer.shadowOpacity = isTargeted ? 0.6 : 0.0
            layer.shadowRadius = isTargeted ? 6 : 0
            layer.shadowOffset = CGSize(width: 0, height: 0)
        }

        override func mouseDown(with event: NSEvent) {
            delegate?.zoneIndicatorActivated(key)
        }
    }

    private final class IndicatorHandle {
        let window: IndicatorWindow
        let view: IndicatorView

        init(window: IndicatorWindow, view: IndicatorView) {
            self.window = window
            self.view = view
        }
    }

    weak var delegate: ZoneIndicatorManagerDelegate?

    private var handles: [ZoneKey: IndicatorHandle] = [:]

    func present(over descriptors: [ZoneIndicatorDescriptor]) {
        var pendingRemoval = Set(handles.keys)

        for descriptor in descriptors {
            let frame = descriptor.cocoaFrame.standardized

            if let handle = handles[descriptor.key] {
                handle.window.setFrame(frame, display: true)
                handle.view.setFrameSize(frame.size)
                handle.view.isTargeted = descriptor.isTargeted
                handle.view.delegate = delegate
                handle.window.orderFrontRegardless()
                pendingRemoval.remove(descriptor.key)
                continue
            }

            let window = IndicatorWindow(frame: frame)
            let view = IndicatorView(frame: NSRect(origin: .zero, size: frame.size), key: descriptor.key, targeted: descriptor.isTargeted)
            view.delegate = delegate
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.orderFrontRegardless()

            let handle = IndicatorHandle(window: window, view: view)
            handles[descriptor.key] = handle
            pendingRemoval.remove(descriptor.key)
        }

        for key in pendingRemoval {
            if let handle = handles.removeValue(forKey: key) {
                handle.window.orderOut(nil)
                handle.window.close()
            }
        }
    }

    func tearDown() {
        for handle in handles.values {
            handle.window.orderOut(nil)
            handle.window.close()
        }
        handles.removeAll()
    }
}
