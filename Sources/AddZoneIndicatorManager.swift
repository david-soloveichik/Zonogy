import Cocoa

/// Renders the vertical "add zone" indicator per screen and routes interactions back to the controller.

// MARK: - Delegate Protocol

protocol AddZoneIndicatorManagerDelegate: AnyObject {
    func addZoneIndicatorManager(_ manager: AddZoneIndicatorManager, didClickIndicatorFor screenId: CGDirectDisplayID)
}

// MARK: - Indicator Window

class AddZoneIndicatorWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        // Follow the active space but avoid joining dedicated full-screen spaces.
        self.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        self.ignoresMouseEvents = false
        self.hasShadow = false
    }
}

// MARK: - Indicator View

class AddZoneIndicatorView: NSView {
    var isHovered = false {
        didSet {
            if isHovered != oldValue {
                needsDisplay = true
            }
        }
    }
    var isDragHighlighted = false {
        didSet {
            if isDragHighlighted != oldValue {
                needsDisplay = true
            }
        }
    }

    weak var delegate: AddZoneIndicatorManagerDelegate?
    var screenId: CGDirectDisplayID = 0
    var manager: AddZoneIndicatorManager?

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let fillColor: NSColor
        let borderColor: NSColor

        if isDragHighlighted {
            fillColor = NSColor.systemBlue.withAlphaComponent(0.35)
            borderColor = NSColor.systemBlue.withAlphaComponent(0.65)
        } else {
            // Background color: white with semi-transparency (less transparent on hover)
            let fillAlpha: CGFloat = isHovered ? 0.8 : 0.55
            fillColor = NSColor.white.withAlphaComponent(fillAlpha)

            // Border color: white with consistent alpha
            let borderAlpha: CGFloat = 0.7
            borderColor = NSColor.white.withAlphaComponent(borderAlpha)
        }

        // Create rounded rectangle path
        let cornerRadius = bounds.width / 2
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)

        // Fill
        context.saveGState()
        fillColor.setFill()
        path.fill()
        context.restoreGState()

        // Border
        context.saveGState()
        borderColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.addZoneIndicatorManager(manager!, didClickIndicatorFor: screenId)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove existing tracking areas
        trackingAreas.forEach { removeTrackingArea($0) }

        // Add new tracking area for hover effects
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
}

// MARK: - Indicator Descriptor

struct AddZoneIndicatorDescriptor {
    let screenId: CGDirectDisplayID
    let frame: CGRect

    init(screenId: CGDirectDisplayID, frame: CGRect) {
        self.screenId = screenId
        self.frame = frame
    }
}

// MARK: - Manager

class AddZoneIndicatorManager {
    weak var delegate: AddZoneIndicatorManagerDelegate?

    private var windows: [CGDirectDisplayID: AddZoneIndicatorWindow] = [:]
    private var views: [CGDirectDisplayID: AddZoneIndicatorView] = [:]
    private var dragHighlightedScreenId: CGDirectDisplayID?

    func present(for descriptors: [AddZoneIndicatorDescriptor]) {
        // Track which screens should have indicators
        let screenIds = Set(descriptors.map { $0.screenId })

        // Remove indicators for screens that no longer need them
        let toRemove = windows.keys.filter { !screenIds.contains($0) }
        for screenId in toRemove {
            windows[screenId]?.close()
            windows.removeValue(forKey: screenId)
            views.removeValue(forKey: screenId)
        }

        // Create or update indicators for each descriptor
        for descriptor in descriptors {
            if let existingWindow = windows[descriptor.screenId],
               let existingView = views[descriptor.screenId] {
                // Update existing indicator
                existingWindow.setFrame(descriptor.frame, display: true)
                existingView.frame = CGRect(origin: .zero, size: descriptor.frame.size)
                existingView.isDragHighlighted = (dragHighlightedScreenId == descriptor.screenId)
            } else {
                // Create new indicator
                let window = AddZoneIndicatorWindow(contentRect: descriptor.frame)
                let view = AddZoneIndicatorView(frame: CGRect(origin: .zero, size: descriptor.frame.size))

                view.delegate = delegate
                view.screenId = descriptor.screenId
                view.manager = self
                view.isDragHighlighted = (dragHighlightedScreenId == descriptor.screenId)

                window.contentView = view
                window.orderFront(nil)

                windows[descriptor.screenId] = window
                views[descriptor.screenId] = view
            }
        }
    }

    func updateDragHighlight(screenId: CGDirectDisplayID?) {
        if dragHighlightedScreenId == screenId {
            return
        }
        dragHighlightedScreenId = screenId
        for (candidateId, view) in views {
            view.isDragHighlighted = (candidateId == screenId)
        }
    }

    func tearDown() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
        views.removeAll()
        dragHighlightedScreenId = nil
    }
}
