import AppKit

struct ZoneSeparatorDescriptor {
    let screenId: CGDirectDisplayID
    let index: Int
    let orientation: ZoneLayout.SeparatorOrientation
    let frame: CGRect // Screen coordinates
}

protocol ZoneResizeHandleManagerDelegate: AnyObject {
    func resizeHandleDragged(screenId: CGDirectDisplayID, separatorIndex: Int, delta: CGPoint)
}

final class ZoneResizeHandleManager {
    private final class HandleWindow: NSPanel {
        init(frame: NSRect) {
            super.init(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            isReleasedWhenClosed = false
            isFloatingPanel = true
            becomesKeyOnlyIfNeeded = false
            ignoresMouseEvents = false
            isOpaque = false
            hasShadow = false
            backgroundColor = .clear
            level = .floating 
            collectionBehavior = [
                .moveToActiveSpace,
                .transient,
                .ignoresCycle,
                .fullScreenAuxiliary
            ]
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class HandleView: NSView {
        weak var delegate: ZoneResizeHandleManagerDelegate?
        let screenId: CGDirectDisplayID
        let separatorIndex: Int
        let orientation: ZoneLayout.SeparatorOrientation
        
        private var isHovering = false
        private var isDragging = false
        private static weak var activeDragView: HandleView?
        
        // Visual bar customization
        private let barThickness: CGFloat = 4.0
        private let barColor = NSColor.white.withAlphaComponent(0.9)
        private let barCornerRadius: CGFloat = 2.0
        private let barInset: CGFloat = 4.0 // Inset from ends of the margin

        init(frame frameRect: NSRect, screenId: CGDirectDisplayID, index: Int, orientation: ZoneLayout.SeparatorOrientation) {
            self.screenId = screenId
            self.separatorIndex = index
            self.orientation = orientation
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            let options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited, .cursorUpdate]
            addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
        }
        
        override func cursorUpdate(with event: NSEvent) {
            switch orientation {
            case .vertical:
                NSCursor.resizeLeftRight.set()
            case .horizontal:
                NSCursor.resizeUpDown.set()
            }
        }
        
        override func mouseEntered(with event: NSEvent) {
            // Prevent other handles from lighting up if a drag is in progress
            if let dragger = HandleView.activeDragView, dragger !== self {
                return
            }
            isHovering = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovering = false
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard isHovering || isDragging else { return }
            
            // Draw the white bar
            // The view frame matches the margin (8px wide/tall)
            // We want to draw a thinner bar centered in it.
            
            let drawRect: NSRect
            switch orientation {
            case .vertical:
                // Center horizontally, inset vertically
                let x = (bounds.width - barThickness) / 2
                let y = barInset
                let height = max(0, bounds.height - (barInset * 2))
                drawRect = NSRect(x: x, y: y, width: barThickness, height: height)
            case .horizontal:
                // Center vertically, inset horizontally
                let y = (bounds.height - barThickness) / 2
                let x = barInset
                let width = max(0, bounds.width - (barInset * 2))
                drawRect = NSRect(x: x, y: y, width: width, height: barThickness)
            }
            
            barColor.setFill()
            let path = NSBezierPath(roundedRect: drawRect, xRadius: barCornerRadius, yRadius: barCornerRadius)
            path.fill()
        }
        
        override func mouseDown(with event: NSEvent) {
            HandleView.activeDragView = self
            isDragging = true
            needsDisplay = true
        }
        
        override func mouseUp(with event: NSEvent) {
            HandleView.activeDragView = nil
            isDragging = false
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            isDragging = true
            needsDisplay = true
            
            // Convert delta to screen coordinates logic if needed
            // event.deltaX/Y are in screen points usually
            // Note: Y direction flip between screen and event delta might be tricky?
            // NSEvent deltaY: + is UP usually?
            // Screen coords: Y increases DOWN.
            // So dragging UP (positive deltaY) means DECREASING Y in screen coords.
            // So deltaY needs to be inverted?
            
            // Actually, let's check AppKit docs or experiment.
            // Usually deltaY is + for up movement.
            // If I drag the horizontal separator UP (deltaY > 0), I want the Y coordinate to DECREASE.
            // So the change in screen coordinate Y is -deltaY.
            
            let delta = CGPoint(x: event.deltaX, y: event.deltaY)
            delegate?.resizeHandleDragged(screenId: screenId, separatorIndex: separatorIndex, delta: delta)
        }
    }

    private final class Handle {
        let window: HandleWindow
        let view: HandleView

        init(window: HandleWindow, view: HandleView) {
            self.window = window
            self.view = view
        }
    }

    weak var delegate: ZoneResizeHandleManagerDelegate?
    private var handles: [String: Handle] = [:] // Key: "screenId-index"

    func present(over descriptors: [ZoneSeparatorDescriptor]) {
        var pendingRemoval = Set(handles.keys)

        for descriptor in descriptors {
            let key = "\(descriptor.screenId)-\(descriptor.index)"
            // Convert screen frame to Cocoa frame for window
            // descriptor.frame is in SCREEN coordinates (Top-Left origin).
            // NSWindow needs Cocoa coordinates (Bottom-Left origin).
            // We need the primary screen height to flip.
            
            let screenFrame = descriptor.frame
            // Assuming we have a helper or we can get primary screen.
            // AppController has CoordinateConversion.
            // But here we are in a manager.
            // We should probably pass cocoaFrame in descriptor or convert here.
            // Let's try to find primary screen.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let cocoaY = primaryHeight - screenFrame.maxY // Flip
            let cocoaFrame = NSRect(x: screenFrame.minX, y: cocoaY, width: screenFrame.width, height: screenFrame.height)

            if let handle = handles[key] {
                if handle.window.frame != cocoaFrame {
                    handle.window.setFrame(cocoaFrame, display: true)
                    handle.view.setFrameSize(cocoaFrame.size) // triggers draw
                    handle.view.needsDisplay = true
                }
                handle.view.delegate = delegate
                handle.window.orderFrontRegardless()
                pendingRemoval.remove(key)
                continue
            }

            let window = HandleWindow(frame: cocoaFrame)
            let view = HandleView(frame: NSRect(origin: .zero, size: cocoaFrame.size), screenId: descriptor.screenId, index: descriptor.index, orientation: descriptor.orientation)
            view.delegate = delegate
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.orderFrontRegardless()

            let handle = Handle(window: window, view: view)
            handles[key] = handle
            pendingRemoval.remove(key)
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