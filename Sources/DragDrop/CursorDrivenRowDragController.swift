import AppKit

/// Shared preview + mouse-monitor driver for cursor-driven row drags.
final class CursorDrivenRowDragController<Payload> {
    private let logPrefix: String
    private let currentCursorAXProvider: () -> CGPoint?
    private let onDidBeginDrag: (Payload) -> Void
    private let onDidUpdateDrag: (CGPoint?) -> Void
    private let onDidEndDrag: (Payload, CGPoint?) -> Void
    private let dragPreview = CursorDrivenDragPreview()

    private var activePayload: Payload?
    private var dragGlobalMonitor: Any?
    private var dragLocalMonitor: Any?

    init(
        logPrefix: String,
        currentCursorAXProvider: @escaping () -> CGPoint?,
        onDidBeginDrag: @escaping (Payload) -> Void,
        onDidUpdateDrag: @escaping (CGPoint?) -> Void,
        onDidEndDrag: @escaping (Payload, CGPoint?) -> Void
    ) {
        self.logPrefix = logPrefix
        self.currentCursorAXProvider = currentCursorAXProvider
        self.onDidBeginDrag = onDidBeginDrag
        self.onDidUpdateDrag = onDidUpdateDrag
        self.onDidEndDrag = onDidEndDrag
    }

    var isDragging: Bool {
        activePayload != nil
    }

    func beginDrag(
        for payload: Payload,
        title: String,
        initialCursorPointCocoa: CGPoint? = nil,
        driveViaMouseMonitors: Bool
    ) {
        guard activePayload == nil else {
            Logger.debug("\(logPrefix): drag already active; ignoring new begin")
            return
        }

        activePayload = payload
        dragPreview.show(title: title, at: initialCursorPointCocoa ?? NSEvent.mouseLocation)
        onDidBeginDrag(payload)

        guard driveViaMouseMonitors else {
            Logger.debug("\(logPrefix): drag session started (externally driven)")
            return
        }

        dragGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        dragLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
        Logger.debug("\(logPrefix): drag session started, mouse monitors installed")
    }

    func updateDrag(cursorPointAX: CGPoint? = nil, cursorPointCocoa: CGPoint? = nil) {
        guard activePayload != nil else { return }
        dragPreview.updatePosition(at: cursorPointCocoa ?? NSEvent.mouseLocation)
        onDidUpdateDrag(cursorPointAX ?? currentCursorAXProvider())
    }

    func endDrag(cursorPointAX: CGPoint? = nil) {
        guard let payload = activePayload else { return }
        tearDownMonitors()
        activePayload = nil
        dragPreview.hide()
        onDidEndDrag(payload, cursorPointAX ?? currentCursorAXProvider())
    }

    func cancelDrag() {
        guard activePayload != nil else { return }
        tearDownMonitors()
        activePayload = nil
        dragPreview.hide()
    }

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            updateDrag()
        case .leftMouseUp:
            endDrag()
        default:
            break
        }
    }

    private func tearDownMonitors() {
        if let monitor = dragGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            dragGlobalMonitor = nil
        }
        if let monitor = dragLocalMonitor {
            NSEvent.removeMonitor(monitor)
            dragLocalMonitor = nil
        }
    }

    deinit {
        tearDownMonitors()
    }
}

/// Floating drag preview that follows the cursor during cursor-driven drags.
private final class CursorDrivenDragPreview {
    private var feedbackWindow: NSWindow?
    private var titleLabel: NSTextField?

    func show(title: String, at mouseLocation: CGPoint) {
        if feedbackWindow == nil {
            createFeedbackWindow()
        }

        guard let feedbackWindow, let titleLabel else { return }

        titleLabel.stringValue = title
        titleLabel.sizeToFit()

        let padding: CGFloat = 16
        let windowSize = NSSize(
            width: min(titleLabel.frame.width + padding * 2, 250),
            height: titleLabel.frame.height + padding
        )
        feedbackWindow.setContentSize(windowSize)

        updatePosition(at: mouseLocation)
        feedbackWindow.alphaValue = 0
        feedbackWindow.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            feedbackWindow.animator().alphaValue = 1
        }
    }

    func updatePosition(at mouseLocation: CGPoint) {
        guard let feedbackWindow else { return }

        let offset = NSPoint(x: 12, y: -20)
        feedbackWindow.setFrameOrigin(NSPoint(
            x: mouseLocation.x + offset.x,
            y: mouseLocation.y + offset.y - feedbackWindow.frame.height
        ))
    }

    func hide() {
        guard let feedbackWindow else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            feedbackWindow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.feedbackWindow?.orderOut(nil)
        })
    }

    private func createFeedbackWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = true

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 8
        visualEffect.layer?.masksToBounds = true
        ForceClickSuppression.apply(to: visualEffect)

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = visualEffect

        let stackView = NSStackView(views: [iconView, label])
        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -10),
            stackView.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
        ])

        feedbackWindow = window
        titleLabel = label
    }
}
