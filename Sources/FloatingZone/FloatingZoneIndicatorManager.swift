import AppKit

/// Renders bottom-edge pills for per-screen floating zone targeting.
struct FloatingZoneIndicatorDescriptor {
    let screenId: CGDirectDisplayID
    let cocoaFrame: CGRect
    let isTargeted: Bool
    let isOccupied: Bool
    let isDragHighlighted: Bool
}

protocol FloatingZoneIndicatorManagerDelegate: AnyObject {
    func floatingZoneIndicatorActivated(screenId: CGDirectDisplayID, wasAlreadyTargeted: Bool, isDoubleClick: Bool)
    func floatingZoneIndicatorReceivedExternalDrop(screenId: CGDirectDisplayID, items: [ExternalDropItem])
}

/// Sizing and timing for the brief "pop" when a floating zone becomes targeted. The floating zone
/// has no border to flash, so its bottom-edge pill momentarily enlarges instead — the floating-zone
/// analog of the tiling-zone border flash.
private enum FloatingIndicatorPulse {
    /// Peak height the pill jumps to before settling back to its resting thickness.
    static let peakThickness: CGFloat = 20
    /// How much wider the pill grows at the peak, centered on its resting midpoint.
    static let widthScale: CGFloat = 1.08
    /// How long the pill takes to settle from the peak back to its resting frame.
    static let duration: CFTimeInterval = 0.32
}

final class FloatingZoneIndicatorManager {
    private final class IndicatorWindow: NSPanel {
        init(frame: NSRect) {
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
            hasShadow = false
            backgroundColor = .clear
            level = .floating
            collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            orderFront(sender)
        }
    }

    private final class IndicatorView: NSView {
        weak var delegate: FloatingZoneIndicatorManagerDelegate?
        weak var manager: FloatingZoneIndicatorManager?
        let screenId: CGDirectDisplayID
        var isTargeted: Bool { didSet { applyStyle() } }
        var isOccupied: Bool { didSet { applyStyle() } }
        var isDragHighlighted: Bool {
            didSet {
                applyStyle()
            }
        }
        private var isExternalDropHover: Bool = false {
            didSet {
                if isExternalDropHover != oldValue {
                    applyStyle()
                    interactionStateChanged?(screenId)
                }
            }
        }
        private var isHovered: Bool = false {
            didSet {
                if isHovered != oldValue {
                    applyStyle()
                    interactionStateChanged?(screenId)
                }
            }
        }

        var interactionStateChanged: ((CGDirectDisplayID) -> Void)?

        private let highlightFillColor = NSColor.systemBlue.withAlphaComponent(0.5)
        private let highlightBorderColor = NSColor.systemBlue.withAlphaComponent(0.9)
        private let targetedFillColor = IndicatorPalette.targetedFillColor
        private let targetedBorderColor = IndicatorPalette.targetedBorderColor
        private let occupiedFillColor = NSColor.systemBlue.withAlphaComponent(0.22)
        private let occupiedBorderColor = NSColor.systemBlue.withAlphaComponent(0.4)
        private let untargetedFillColor = NSColor.systemBlue.withAlphaComponent(0.12)
        private let untargetedBorderColor = NSColor.systemBlue.withAlphaComponent(0.25)
        private let hoverFillColor = NSColor.systemBlue.withAlphaComponent(0.3)
        private let hoverBorderColor = NSColor.systemBlue.withAlphaComponent(0.6)
        private let hoverShadowColor = NSColor.systemBlue.withAlphaComponent(0.55).cgColor
        private let hoverShadowOpacity: Float = 0.55
        private let hoverShadowRadius: CGFloat = 7

        init(frame frameRect: NSRect, screenId: CGDirectDisplayID, targeted: Bool, occupied: Bool, dragHighlighted: Bool) {
            self.screenId = screenId
            self.isTargeted = targeted
            self.isOccupied = occupied
            self.isDragHighlighted = dragHighlighted
            super.init(frame: frameRect)
            wantsLayer = true
            ForceClickSuppression.apply(to: self)
            if #available(macOS 10.15, *) {
                layer?.cornerCurve = .continuous
            }
            registerForDraggedTypes(ExternalDropParser.registeredPasteboardTypes)
            applyStyle()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private var trackingArea: NSTrackingArea?
        private var hoverExitWorkItem: DispatchWorkItem?
        private let hoverExitDelay: TimeInterval = 0.06
        private let hoverHysteresisPadding: CGFloat = 2.0

        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.height / 2
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingArea == nil else {
                return
            }

            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            cancelPendingHoverExit()
            isHovered = true
        }

        override func mouseExited(with event: NSEvent) {
            scheduleHoverExitIfNeeded()
        }

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

        func desiredThickness() -> CGFloat {
            if isDragHighlighted || isExternalDropHover {
                return EdgeIndicatorPillSizing.dragThickness
            }
            if isHovered {
                return EdgeIndicatorPillSizing.hoverThickness
            }
            return EdgeIndicatorPillSizing.baseThickness
        }

        private func applyStyle() {
            guard let layer else { return }
            let background: NSColor
            let border: NSColor
            let shadowColor: CGColor
            let shadowOpacity: Float
            let shadowRadius: CGFloat
            let borderWidth: CGFloat

            if isDragHighlighted || isExternalDropHover {
                background = highlightFillColor
                border = highlightBorderColor
                shadowColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
                shadowOpacity = 1.0
                shadowRadius = 9
                borderWidth = 1.9
            } else if isTargeted {
                background = targetedFillColor
                border = targetedBorderColor
                shadowColor = IndicatorPalette.targetedShadowColor.cgColor
                shadowOpacity = IndicatorPalette.targetedShadowOpacity
                shadowRadius = IndicatorPalette.targetedShadowRadius
                borderWidth = IndicatorPalette.defaultBorderWidth
            } else if isHovered {
                background = hoverFillColor
                border = hoverBorderColor
                shadowColor = hoverShadowColor
                shadowOpacity = hoverShadowOpacity
                shadowRadius = hoverShadowRadius
                borderWidth = IndicatorPalette.defaultBorderWidth + 0.2
            } else if isOccupied {
                background = occupiedFillColor
                border = occupiedBorderColor
                shadowColor = NSColor.clear.cgColor
                shadowOpacity = 0
                shadowRadius = 0
                borderWidth = IndicatorPalette.defaultBorderWidth
            } else {
                background = untargetedFillColor
                border = untargetedBorderColor
                shadowColor = NSColor.clear.cgColor
                shadowOpacity = 0
                shadowRadius = 0
                borderWidth = IndicatorPalette.defaultBorderWidth
            }

            layer.backgroundColor = background.cgColor
            layer.borderWidth = borderWidth
            layer.borderColor = border.cgColor
            layer.shadowColor = shadowColor
            layer.shadowOpacity = shadowOpacity
            layer.shadowRadius = shadowRadius
            layer.shadowOffset = .zero
        }

        override func mouseDown(with event: NSEvent) {
            let isDoubleClick = event.clickCount >= 2
            delegate?.floatingZoneIndicatorActivated(screenId: screenId, wasAlreadyTargeted: isTargeted, isDoubleClick: isDoubleClick)
        }

        // MARK: - NSDraggingDestination

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
    }

    private final class IndicatorHandle {
        let window: IndicatorWindow
        let view: IndicatorView
        var baseFrame: CGRect

        init(window: IndicatorWindow, view: IndicatorView, baseFrame: CGRect) {
            self.window = window
            self.view = view
            self.baseFrame = baseFrame
        }
    }

    weak var delegate: FloatingZoneIndicatorManagerDelegate?
    private var handles: [CGDirectDisplayID: IndicatorHandle] = [:]
    private var dragHighlightedScreenId: CGDirectDisplayID?
    /// Screens whose pill is mid-pulse, keyed by a generation counter. While a screen is pulsing,
    /// `applyIndicatorFrame` leaves its frame alone so the frequent indicator refreshes (which call
    /// `applyIndicatorFrame(animated: false)`) don't snap the pill back and cut the pop short. The
    /// generation lets a newer pulse supersede an older one without the older's completion settling.
    private var pulseGenerations: [CGDirectDisplayID: Int] = [:]

    func present(over descriptors: [FloatingZoneIndicatorDescriptor]) {
        var pendingRemoval = Set(handles.keys)

        for descriptor in descriptors {
            let baseFrame = descriptor.cocoaFrame.standardized
            if let handle = handles[descriptor.screenId] {
                handle.baseFrame = baseFrame
                handle.view.isTargeted = descriptor.isTargeted
                handle.view.isOccupied = descriptor.isOccupied
                handle.view.isDragHighlighted = descriptor.isDragHighlighted
                handle.view.delegate = delegate
                handle.view.manager = self
                handle.view.interactionStateChanged = { [weak self] screenId in
                    self?.applyIndicatorFrame(for: screenId, animated: true)
                }
                applyIndicatorFrame(for: descriptor.screenId, animated: false)
                pendingRemoval.remove(descriptor.screenId)
                continue
            }

            let window = IndicatorWindow(frame: baseFrame)
            let view = IndicatorView(
                frame: NSRect(origin: .zero, size: baseFrame.size),
                screenId: descriptor.screenId,
                targeted: descriptor.isTargeted,
                occupied: descriptor.isOccupied,
                dragHighlighted: descriptor.isDragHighlighted
            )
            view.delegate = delegate
            view.manager = self
            view.autoresizingMask = [.width, .height]
            view.interactionStateChanged = { [weak self] screenId in
                self?.applyIndicatorFrame(for: screenId, animated: true)
            }
            window.contentView = view
            window.orderFrontRegardless()

            handles[descriptor.screenId] = IndicatorHandle(window: window, view: view, baseFrame: baseFrame)
            pendingRemoval.remove(descriptor.screenId)

            applyIndicatorFrame(for: descriptor.screenId, animated: false)
        }

        for key in pendingRemoval {
            if let handle = handles.removeValue(forKey: key) {
                pulseGenerations[key] = nil
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
        pulseGenerations.removeAll()
        dragHighlightedScreenId = nil
    }

    /// The frame the pill settles to for its current interaction state: hover/drag grow its
    /// thickness, otherwise it rests at its base frame. The pulse animation reads this to know
    /// where to land.
    private func restingFrame(for handle: IndicatorHandle) -> CGRect {
        var frame = handle.baseFrame
        let thickness = handle.view.desiredThickness()
        if thickness > EdgeIndicatorPillSizing.baseThickness {
            frame.size.height = thickness
        }
        return frame
    }

    /// Briefly "pops" the floating-zone pill larger when its zone becomes targeted, then settles it
    /// back to the resting frame — the floating-zone analog of the tiling-zone border flash. The
    /// pill jumps to the enlarged size immediately (anchored to the screen bottom, centered on its
    /// resting midpoint) and animates back down, mirroring how the flash starts thick and thins out.
    func pulseTargeted(screenId: CGDirectDisplayID) {
        guard let handle = handles[screenId] else {
            return
        }

        let generation = (pulseGenerations[screenId] ?? 0) + 1
        pulseGenerations[screenId] = generation

        let resting = restingFrame(for: handle)
        let poppedWidth = resting.width * FloatingIndicatorPulse.widthScale
        let popped = CGRect(
            x: resting.midX - poppedWidth / 2,
            y: resting.origin.y,
            width: poppedWidth,
            height: FloatingIndicatorPulse.peakThickness
        ).standardized

        // Float above neighboring windows for the pop so it reads clearly, then animate back down.
        handle.window.level = .statusBar
        handle.window.orderFrontRegardless()
        handle.window.setFrame(popped, display: true)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = FloatingIndicatorPulse.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            handle.window.animator().setFrame(resting, display: true)
        }, completionHandler: { [weak self] in
            guard let self,
                  self.pulseGenerations[screenId] == generation else {
                // A newer pulse (or teardown) superseded this one; let it own the frame.
                return
            }
            self.pulseGenerations[screenId] = nil
            // Settle into whatever the current interaction state dictates now the pop is done.
            self.applyIndicatorFrame(for: screenId, animated: false)
        })
    }

    private func applyIndicatorFrame(for screenId: CGDirectDisplayID, animated: Bool) {
        guard let handle = handles[screenId] else {
            return
        }

        // A pulse owns the frame for its whole duration; don't let a refresh snap it back mid-pop.
        if pulseGenerations[screenId] != nil {
            return
        }

        let targetFrame = restingFrame(for: handle)
        let shouldFloatOnTop = targetFrame.height > EdgeIndicatorPillSizing.baseThickness

        let targetLevel: NSWindow.Level = shouldFloatOnTop ? .statusBar : .floating
        if handle.window.level != targetLevel {
            handle.window.level = targetLevel
        }
        if shouldFloatOnTop || handle.view.isTargeted || handle.view.isDragHighlighted {
            handle.window.orderFrontRegardless()
        }

        if targetFrame == handle.window.frame {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                handle.window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            handle.window.setFrame(targetFrame, display: true)
        }
    }

    func updateDragHighlight(screenId: CGDirectDisplayID?) {
        if dragHighlightedScreenId == screenId {
            return
        }
        dragHighlightedScreenId = screenId
        for (candidate, handle) in handles {
            handle.view.isDragHighlighted = (candidate == screenId)
            applyIndicatorFrame(for: candidate, animated: true)
        }
    }

    func handleExternalDrop(from draggingInfo: NSDraggingInfo, on screenId: CGDirectDisplayID) -> Bool {
        guard let payload = ExternalDropParser.payload(from: draggingInfo) else {
            return false
        }
        delegate?.floatingZoneIndicatorReceivedExternalDrop(screenId: screenId, items: payload.items)
        return true
    }
}
