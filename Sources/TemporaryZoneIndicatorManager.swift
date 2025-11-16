import AppKit

/// Renders bottom-edge pills for per-screen temporary zone targeting.
struct TemporaryZoneIndicatorDescriptor {
    let screenId: CGDirectDisplayID
    let cocoaFrame: CGRect
    let isTargeted: Bool
    let isOccupied: Bool
    let isDragHighlighted: Bool
}

protocol TemporaryZoneIndicatorManagerDelegate: AnyObject {
    func temporaryZoneIndicatorActivated(screenId: CGDirectDisplayID)
}

final class TemporaryZoneIndicatorManager {
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
            let normalRaw = Int(CGWindowLevelForKey(.normalWindow))
            level = NSWindow.Level(rawValue: normalRaw - 1)
            collectionBehavior = [.moveToActiveSpace, .transient]
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class IndicatorView: NSView {
        weak var delegate: TemporaryZoneIndicatorManagerDelegate?
        let screenId: CGDirectDisplayID
        var isTargeted: Bool { didSet { applyStyle() } }
        var isOccupied: Bool { didSet { applyStyle() } }
        var isDragHighlighted: Bool { didSet { applyStyle() } }

        private let targetedColor = NSColor.systemBlue.withAlphaComponent(0.55)
        private let targetedBorder = NSColor.systemBlue.withAlphaComponent(0.75)
        private let occupiedColor = NSColor.systemBlue.withAlphaComponent(0.3)
        private let occupiedBorder = NSColor.systemBlue.withAlphaComponent(0.5)
        private let untargetedColor = NSColor.systemBlue.withAlphaComponent(0.18)
        private let untargetedBorder = NSColor.systemBlue.withAlphaComponent(0.35)

        init(frame frameRect: NSRect, screenId: CGDirectDisplayID, targeted: Bool, occupied: Bool, dragHighlighted: Bool) {
            self.screenId = screenId
            self.isTargeted = targeted
            self.isOccupied = occupied
            self.isDragHighlighted = dragHighlighted
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
            guard let layer else { return }
            let background: NSColor
            let border: NSColor

            let active = isTargeted || isDragHighlighted
            if active {
                background = targetedColor
                border = targetedBorder
            } else if isOccupied {
                background = occupiedColor
                border = occupiedBorder
            } else {
                background = untargetedColor
                border = untargetedBorder
            }

            layer.backgroundColor = background.cgColor
            layer.borderWidth = 1.2
            layer.borderColor = border.cgColor
            layer.shadowColor = NSColor.systemBlue.withAlphaComponent(isTargeted ? 0.6 : 0.0).cgColor
            layer.shadowOpacity = isTargeted ? 0.6 : 0.0
            layer.shadowRadius = isTargeted ? 6 : 0
            layer.shadowOffset = .zero
        }

        override func mouseDown(with event: NSEvent) {
            delegate?.temporaryZoneIndicatorActivated(screenId: screenId)
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

    weak var delegate: TemporaryZoneIndicatorManagerDelegate?
    private var handles: [CGDirectDisplayID: IndicatorHandle] = [:]
    private var dragHighlightedScreenId: CGDirectDisplayID?

    func present(over descriptors: [TemporaryZoneIndicatorDescriptor]) {
        var pendingRemoval = Set(handles.keys)

        for descriptor in descriptors {
            let frame = descriptor.cocoaFrame.standardized
            if let handle = handles[descriptor.screenId] {
                handle.window.setFrame(frame, display: true)
                handle.view.frame = NSRect(origin: .zero, size: frame.size)
                handle.view.isTargeted = descriptor.isTargeted
                handle.view.isOccupied = descriptor.isOccupied
                handle.view.isDragHighlighted = descriptor.isDragHighlighted
                handle.view.delegate = delegate
                pendingRemoval.remove(descriptor.screenId)
                continue
            }

            let window = IndicatorWindow(frame: frame)
            let view = IndicatorView(
                frame: NSRect(origin: .zero, size: frame.size),
                screenId: descriptor.screenId,
                targeted: descriptor.isTargeted,
                occupied: descriptor.isOccupied,
                dragHighlighted: descriptor.isDragHighlighted
            )
            view.delegate = delegate
            window.contentView = view
            window.orderFrontRegardless()

            handles[descriptor.screenId] = IndicatorHandle(window: window, view: view)
            pendingRemoval.remove(descriptor.screenId)
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
        dragHighlightedScreenId = nil
    }

    func updateDragHighlight(screenId: CGDirectDisplayID?) {
        if dragHighlightedScreenId == screenId {
            return
        }
        dragHighlightedScreenId = screenId
        for (candidate, handle) in handles {
            handle.view.isDragHighlighted = (candidate == screenId)
        }
    }
}
