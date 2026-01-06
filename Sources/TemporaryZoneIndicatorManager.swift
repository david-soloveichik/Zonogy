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
    func temporaryZoneIndicatorActivated(screenId: CGDirectDisplayID, wasAlreadyTargeted: Bool, isDoubleClick: Bool)
}

final class TemporaryZoneIndicatorManager {
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
        weak var delegate: TemporaryZoneIndicatorManagerDelegate?
        let screenId: CGDirectDisplayID
        var isTargeted: Bool { didSet { applyStyle() } }
        var isOccupied: Bool { didSet { applyStyle() } }
        var isDragHighlighted: Bool {
            didSet {
                applyStyle()
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
            if #available(macOS 10.15, *) {
                layer?.cornerCurve = .continuous
            }
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
                let paddedBounds = self.bounds.insetBy(dx: -self.hoverHysteresisPadding, dy: -self.hoverHysteresisPadding)
                if paddedBounds.contains(localPoint) {
                    return
                }

                self.isHovered = false
            }

            hoverExitWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverExitDelay, execute: workItem)
        }

        func desiredThickness() -> CGFloat {
            if isDragHighlighted {
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

            if isDragHighlighted {
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
            delegate?.temporaryZoneIndicatorActivated(screenId: screenId, wasAlreadyTargeted: isTargeted, isDoubleClick: isDoubleClick)
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

    weak var delegate: TemporaryZoneIndicatorManagerDelegate?
    private var handles: [CGDirectDisplayID: IndicatorHandle] = [:]
    private var dragHighlightedScreenId: CGDirectDisplayID?

    func present(over descriptors: [TemporaryZoneIndicatorDescriptor]) {
        var pendingRemoval = Set(handles.keys)

        for descriptor in descriptors {
            let baseFrame = descriptor.cocoaFrame.standardized
            if let handle = handles[descriptor.screenId] {
                handle.baseFrame = baseFrame
                handle.view.isTargeted = descriptor.isTargeted
                handle.view.isOccupied = descriptor.isOccupied
                handle.view.isDragHighlighted = descriptor.isDragHighlighted
                handle.view.delegate = delegate
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

    private func applyIndicatorFrame(for screenId: CGDirectDisplayID, animated: Bool) {
        guard let handle = handles[screenId] else {
            return
        }

        let thickness = handle.view.desiredThickness()
        let shouldFloatOnTop = thickness > EdgeIndicatorPillSizing.baseThickness

        var targetFrame = handle.baseFrame
        if shouldFloatOnTop {
            targetFrame.size.height = thickness
        }

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
}
