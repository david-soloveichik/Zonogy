import AppKit

/// Manages translucent zone overlays shown during window drag operations.
struct ZoneOverlayDescriptor {
    let key: ZoneKey
    let cocoaFrame: CGRect
    let isEmpty: Bool
}

protocol DragOverlayExternalDropDelegate: AnyObject {
    func dragOverlayManager(_ manager: DragOverlayManager, shouldAcceptExternalDropFor key: ZoneKey) -> Bool
    func dragOverlayManager(_ manager: DragOverlayManager, didReceiveExternalDrop items: [ExternalDropItem], for key: ZoneKey)
}

final class DragOverlayManager {
    private final class PassiveOverlayWindow: NSWindow {
        init(frame: NSRect, windowLevel: NSWindow.Level) {
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
            level = windowLevel
            collectionBehavior = [
                .canJoinAllSpaces,
                .transient,
                .fullScreenAuxiliary
            ]
        }
    }

    private final class InteractiveOverlayWindow: NSPanel {
        init(frame: NSRect, windowLevel: NSWindow.Level) {
            super.init(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            isReleasedWhenClosed = false
            isFloatingPanel = false
            becomesKeyOnlyIfNeeded = false
            ignoresMouseEvents = false
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            level = windowLevel
            collectionBehavior = [
                .canJoinAllSpaces,
                .transient,
                .fullScreenAuxiliary
            ]
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            orderFront(sender)
        }
    }

    private final class OverlayView: NSView {
        let key: ZoneKey
        weak var manager: DragOverlayManager?

        override var isFlipped: Bool {
            true
        }

        init(frame frameRect: NSRect, key: ZoneKey, manager: DragOverlayManager) {
            self.key = key
            self.manager = manager
            super.init(frame: frameRect)
            ForceClickSuppression.apply(to: self)
            if manager.interactiveExternalDrop {
                registerForDraggedTypes(ExternalDropParser.registeredPasteboardTypes)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

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

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard manager?.canAcceptExternalDrop(from: sender, for: key) == true else {
                return []
            }
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard manager?.canAcceptExternalDrop(from: sender, for: key) == true else {
                return []
            }
            return .copy
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            manager?.canAcceptExternalDrop(from: sender, for: key) == true
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            manager?.handleExternalDrop(from: sender, for: key) ?? false
        }
    }

    private final class OverlayHandle {
        let window: NSWindow
        let view: OverlayView
        var isEmpty: Bool

        init(window: NSWindow, view: OverlayView, isEmpty: Bool) {
            self.window = window
            self.view = view
            self.isEmpty = isEmpty
        }
    }

    weak var externalDropDelegate: DragOverlayExternalDropDelegate?

    private let interactiveExternalDrop: Bool
    private let windowLevel: NSWindow.Level
    private var overlays: [ZoneKey: OverlayHandle] = [:]
    private let occupiedBaseColor = NSColor.systemBlue.withAlphaComponent(0.14)
    private let emptyBaseColor = NSColor.systemBlue.withAlphaComponent(0.08)
    private let highlightColor = NSColor.systemBlue.withAlphaComponent(0.32)
    private let baseBorderColor = NSColor.systemBlue.withAlphaComponent(0.28)
    private let highlightBorderColor = NSColor.systemBlue.withAlphaComponent(0.55)

    init(
        externalDropDelegate: DragOverlayExternalDropDelegate? = nil,
        windowLevel: NSWindow.Level = .floating
    ) {
        self.externalDropDelegate = externalDropDelegate
        self.interactiveExternalDrop = (externalDropDelegate != nil)
        self.windowLevel = windowLevel
    }

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

            let window: NSWindow
            if interactiveExternalDrop {
                window = InteractiveOverlayWindow(frame: frame, windowLevel: windowLevel)
            } else {
                window = PassiveOverlayWindow(frame: frame, windowLevel: windowLevel)
            }
            let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size), key: descriptor.key, manager: self)
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
        if !overlays.isEmpty {
            Logger.debug("DragOverlayManager: tearDown closing \(overlays.count) overlay window(s)")
        }
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

    fileprivate func canAcceptExternalDrop(from draggingInfo: NSDraggingInfo, for key: ZoneKey) -> Bool {
        guard interactiveExternalDrop,
              ExternalDropParser.canAccept(draggingInfo),
              externalDropDelegate?.dragOverlayManager(self, shouldAcceptExternalDropFor: key) == true else {
            return false
        }
        return true
    }

    fileprivate func handleExternalDrop(from draggingInfo: NSDraggingInfo, for key: ZoneKey) -> Bool {
        guard interactiveExternalDrop,
              externalDropDelegate?.dragOverlayManager(self, shouldAcceptExternalDropFor: key) == true,
              let payload = ExternalDropParser.payload(from: draggingInfo) else {
            return false
        }
        externalDropDelegate?.dragOverlayManager(self, didReceiveExternalDrop: payload.items, for: key)
        return true
    }
}
