import Cocoa

/// Renders the vertical "add zone" indicator per screen and routes interactions back to the controller.

// MARK: - Delegate Protocol

protocol AddZoneIndicatorManagerDelegate: AnyObject {
    func addZoneIndicatorManager(_ manager: AddZoneIndicatorManager, didClickIndicatorFor screenId: CGDirectDisplayID)
    func addZoneIndicatorManager(
        _ manager: AddZoneIndicatorManager,
        didReceiveExternalDrop items: [ExternalDropItem],
        for screenId: CGDirectDisplayID
    )
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
                manager?.updateIndicatorThickness(for: screenId, animated: true)
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
    private var isExternalDropHover = false {
        didSet {
            if isExternalDropHover != oldValue {
                needsDisplay = true
                manager?.updateIndicatorThickness(for: screenId, animated: true)
            }
        }
    }

    weak var delegate: AddZoneIndicatorManagerDelegate?
    var screenId: CGDirectDisplayID = 0
    var manager: AddZoneIndicatorManager?

    override var acceptsFirstResponder: Bool { false }

    var desiredThickness: CGFloat {
        if isDragHighlighted || isExternalDropHover {
            return EdgeIndicatorPillSizing.dragThickness
        }
        if isHovered {
            return EdgeIndicatorPillSizing.hoverThickness
        }
        return EdgeIndicatorPillSizing.baseThickness
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let fillColor: NSColor
        let borderColor: NSColor

        if isDragHighlighted || isExternalDropHover {
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
        cancelPendingHoverExit()
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        scheduleHoverExitIfNeeded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        guard trackingArea == nil else {
            return
        }

        // Add new tracking area for hover effects
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ExternalDropParser.canAccept(sender) else {
            return []
        }
        isExternalDropHover = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return isExternalDropHover ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isExternalDropHover = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isExternalDropHover = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return ExternalDropParser.canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isExternalDropHover = false
        return manager?.handleExternalDrop(from: sender, on: screenId) ?? false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ForceClickSuppression.apply(to: self)
        registerForDraggedTypes(ExternalDropParser.registeredPasteboardTypes)
    }

    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        ForceClickSuppression.apply(to: self)
        registerForDraggedTypes(ExternalDropParser.registeredPasteboardTypes)
    }

    private var trackingArea: NSTrackingArea?
    private var hoverExitWorkItem: DispatchWorkItem?
    private let hoverExitDelay: TimeInterval = 0.06
    private let hoverHysteresisPadding: CGFloat = 2.0

    private func cancelPendingHoverExit() {
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
    }

    private func scheduleHoverExitIfNeeded() {
        cancelPendingHoverExit()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverExitWorkItem = nil
            guard let window else {
                self.isHovered = false
                return
            }

            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let localPoint = self.convert(windowPoint, from: nil)
            switch EdgeIndicatorHoverExitPolicy.action(
                localPoint: localPoint,
                bounds: self.bounds,
                hysteresisPadding: self.hoverHysteresisPadding
            ) {
            case .keepHover:
                return
            case .recheckAfterDelay:
                self.scheduleHoverExitIfNeeded()
                return
            case .clearHover:
                self.isHovered = false
            }
        }

        hoverExitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverExitDelay, execute: workItem)
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
    private var baseFrames: [CGDirectDisplayID: CGRect] = [:]
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
            baseFrames.removeValue(forKey: screenId)
        }

        // Create or update indicators for each descriptor
        for descriptor in descriptors {
            let baseFrame = descriptor.frame.standardized
            baseFrames[descriptor.screenId] = baseFrame

            if let existingView = views[descriptor.screenId],
               windows[descriptor.screenId] != nil {
                // Update existing indicator
                existingView.isDragHighlighted = (dragHighlightedScreenId == descriptor.screenId)
                existingView.autoresizingMask = [.width, .height]
                applyIndicatorFrame(for: descriptor.screenId, animated: false)
            } else {
                // Create new indicator
                let window = AddZoneIndicatorWindow(contentRect: baseFrame)
                let view = AddZoneIndicatorView(frame: CGRect(origin: .zero, size: baseFrame.size))

                view.delegate = delegate
                view.screenId = descriptor.screenId
                view.manager = self
                view.isDragHighlighted = (dragHighlightedScreenId == descriptor.screenId)
                view.autoresizingMask = [.width, .height]

                window.contentView = view
                window.orderFront(nil)

                windows[descriptor.screenId] = window
                views[descriptor.screenId] = view

                applyIndicatorFrame(for: descriptor.screenId, animated: false)
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
            applyIndicatorFrame(for: candidateId, animated: true)
        }
    }

    func updateIndicatorThickness(for screenId: CGDirectDisplayID, animated: Bool) {
        applyIndicatorFrame(for: screenId, animated: animated)
    }

    private func applyIndicatorFrame(for screenId: CGDirectDisplayID, animated: Bool) {
        guard let baseFrame = baseFrames[screenId],
              let window = windows[screenId],
              let view = views[screenId] else {
            return
        }

        let thickness = view.desiredThickness
        let shouldFloatOnTop = thickness > EdgeIndicatorPillSizing.baseThickness

        var targetFrame = baseFrame
        if shouldFloatOnTop {
            targetFrame.origin.x = baseFrame.maxX - thickness
            targetFrame.size.width = thickness
        }

        let targetLevel: NSWindow.Level = shouldFloatOnTop ? .statusBar : .floating
        if window.level != targetLevel {
            window.level = targetLevel
        }
        if shouldFloatOnTop {
            window.orderFrontRegardless()
        }

        if targetFrame == window.frame {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            window.setFrame(targetFrame, display: true)
        }
    }

    func handleExternalDrop(from draggingInfo: NSDraggingInfo, on screenId: CGDirectDisplayID) -> Bool {
        guard let payload = ExternalDropParser.payload(from: draggingInfo) else {
            return false
        }
        delegate?.addZoneIndicatorManager(
            self,
            didReceiveExternalDrop: payload.items,
            for: screenId
        )
        return true
    }

    func tearDown() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
        views.removeAll()
        baseFrames.removeAll()
        dragHighlightedScreenId = nil
    }
}
