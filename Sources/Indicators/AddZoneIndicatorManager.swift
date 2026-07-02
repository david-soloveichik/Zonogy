import Cocoa

/// Renders the vertical "add zone" bars on screen edges and routes interactions back to the controller.
/// A screen shows one bar per layout-style edge with remaining zone capacity.

/// Identifies one add-zone bar: a screen edge on a specific screen.
struct AddZonePillKey: Hashable {
    let screenId: CGDirectDisplayID
    let side: ZoneSide
}

// MARK: - Delegate Protocol

protocol AddZoneIndicatorManagerDelegate: AnyObject {
    func addZoneIndicatorManager(_ manager: AddZoneIndicatorManager, didClickIndicatorFor pill: AddZonePillKey)
    func addZoneIndicatorManager(
        _ manager: AddZoneIndicatorManager,
        didReceiveExternalDrop items: [ExternalDropItem],
        for pill: AddZonePillKey
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
        // Above the Dock: a Dock sharing this screen edge must not capture the pill's
        // hovers, clicks, or drops.
        self.level = EdgeIndicatorWindowLevel.resting
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
                manager?.updateIndicatorThickness(for: pill, animated: true)
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
                manager?.updateIndicatorThickness(for: pill, animated: true)
            }
        }
    }

    weak var delegate: AddZoneIndicatorManagerDelegate?
    var pill = AddZonePillKey(screenId: 0, side: .right)
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
        delegate?.addZoneIndicatorManager(manager!, didClickIndicatorFor: pill)
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
        return manager?.handleExternalDrop(from: sender, on: pill) ?? false
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
    let pill: AddZonePillKey
    let frame: CGRect

    init(pill: AddZonePillKey, frame: CGRect) {
        self.pill = pill
        self.frame = frame
    }
}

// MARK: - Manager

class AddZoneIndicatorManager {
    weak var delegate: AddZoneIndicatorManagerDelegate?

    private var windows: [AddZonePillKey: AddZoneIndicatorWindow] = [:]
    private var views: [AddZonePillKey: AddZoneIndicatorView] = [:]
    private var baseFrames: [AddZonePillKey: CGRect] = [:]
    private var dragHighlightedPill: AddZonePillKey?
    private var mousePassthroughForUnmanagedWindowEdgeDrag = false

    func present(for descriptors: [AddZoneIndicatorDescriptor]) {
        // Track which pills should have indicators
        let pills = Set(descriptors.map { $0.pill })

        // Remove indicators for pills that no longer need them
        let toRemove = windows.keys.filter { !pills.contains($0) }
        for pill in toRemove {
            windows[pill]?.close()
            windows.removeValue(forKey: pill)
            views.removeValue(forKey: pill)
            baseFrames.removeValue(forKey: pill)
        }

        // Create or update indicators for each descriptor
        for descriptor in descriptors {
            let baseFrame = descriptor.frame.standardized
            baseFrames[descriptor.pill] = baseFrame

            if let existingView = views[descriptor.pill],
               let existingWindow = windows[descriptor.pill] {
                // Update existing indicator
                existingWindow.ignoresMouseEvents = mousePassthroughForUnmanagedWindowEdgeDrag
                existingView.isDragHighlighted = (dragHighlightedPill == descriptor.pill)
                existingView.autoresizingMask = [.width, .height]
                applyIndicatorFrame(for: descriptor.pill, animated: false)
            } else {
                // Create new indicator
                let window = AddZoneIndicatorWindow(contentRect: baseFrame)
                let view = AddZoneIndicatorView(frame: CGRect(origin: .zero, size: baseFrame.size))

                window.ignoresMouseEvents = mousePassthroughForUnmanagedWindowEdgeDrag
                view.delegate = delegate
                view.pill = descriptor.pill
                view.manager = self
                view.isDragHighlighted = (dragHighlightedPill == descriptor.pill)
                view.autoresizingMask = [.width, .height]

                window.contentView = view
                window.orderFront(nil)

                windows[descriptor.pill] = window
                views[descriptor.pill] = view

                applyIndicatorFrame(for: descriptor.pill, animated: false)
            }
        }
    }

    func setMousePassthroughForUnmanagedWindowEdgeDrag(_ enabled: Bool) {
        guard mousePassthroughForUnmanagedWindowEdgeDrag != enabled else {
            return
        }
        mousePassthroughForUnmanagedWindowEdgeDrag = enabled
        for window in windows.values {
            window.ignoresMouseEvents = enabled
        }
    }

    func updateDragHighlight(pill: AddZonePillKey?) {
        if dragHighlightedPill == pill {
            return
        }
        dragHighlightedPill = pill
        for (candidate, view) in views {
            view.isDragHighlighted = (candidate == pill)
            applyIndicatorFrame(for: candidate, animated: true)
        }
    }

    func updateIndicatorThickness(for pill: AddZonePillKey, animated: Bool) {
        applyIndicatorFrame(for: pill, animated: animated)
    }

    private func applyIndicatorFrame(for pill: AddZonePillKey, animated: Bool) {
        guard let baseFrame = baseFrames[pill],
              let window = windows[pill],
              let view = views[pill] else {
            return
        }

        let thickness = view.desiredThickness
        let shouldFloatOnTop = thickness > EdgeIndicatorPillSizing.baseThickness

        // The bar stays anchored to its screen edge and grows inward toward the screen center.
        var targetFrame = baseFrame
        if shouldFloatOnTop {
            switch pill.side {
            case .right:
                targetFrame.origin.x = baseFrame.maxX - thickness
            case .left:
                targetFrame.origin.x = baseFrame.minX
            }
            targetFrame.size.width = thickness
        }

        let targetLevel: NSWindow.Level = shouldFloatOnTop
            ? EdgeIndicatorWindowLevel.raised
            : EdgeIndicatorWindowLevel.resting
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

    func handleExternalDrop(from draggingInfo: NSDraggingInfo, on pill: AddZonePillKey) -> Bool {
        guard let payload = ExternalDropParser.payload(from: draggingInfo) else {
            return false
        }
        delegate?.addZoneIndicatorManager(
            self,
            didReceiveExternalDrop: payload.items,
            for: pill
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
        dragHighlightedPill = nil
    }
}
