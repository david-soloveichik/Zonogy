import AppKit

/// Describes the dynamic "new window" affordance for a cursor-driven drag. When the
/// caller provides one of these, the drag controller observes Option-key state during
/// the drag and toggles the preview between `normalTitle` (Option not held) and
/// `alternateTitle` (Option held), also showing a "+" badge in the Option-held state.
struct NewWindowAffordance {
    let normalTitle: String
    let alternateTitle: String
}

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
    private var flagsGlobalMonitor: Any?
    private var flagsLocalMonitor: Any?
    private var newWindowAffordance: NewWindowAffordance?

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
        driveViaMouseMonitors: Bool,
        newWindowAffordance: NewWindowAffordance? = nil
    ) {
        guard activePayload == nil else {
            Logger.debug("\(logPrefix): drag already active; ignoring new begin")
            return
        }

        activePayload = payload
        self.newWindowAffordance = newWindowAffordance

        let isOption = newWindowAffordance != nil && NSEvent.modifierFlags.contains(.option)
        dragPreview.show(
            title: previewTitle(forOptionHeld: isOption, fallback: title),
            at: initialCursorPointCocoa ?? NSEvent.mouseLocation,
            showsNewWindowAffordance: isOption
        )
        onDidBeginDrag(payload)

        if newWindowAffordance != nil {
            installFlagsMonitors()
        }

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
        newWindowAffordance = nil
        dragPreview.hide()
        onDidEndDrag(payload, cursorPointAX ?? currentCursorAXProvider())
    }

    func cancelDrag() {
        guard activePayload != nil else { return }
        tearDownMonitors()
        activePayload = nil
        newWindowAffordance = nil
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

    private func installFlagsMonitors() {
        flagsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        flagsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let affordance = newWindowAffordance else { return }
        let isOption = event.modifierFlags.contains(.option)
        dragPreview.update(
            title: isOption ? affordance.alternateTitle : affordance.normalTitle,
            showsNewWindowAffordance: isOption
        )
    }

    private func previewTitle(forOptionHeld isOption: Bool, fallback: String) -> String {
        guard let affordance = newWindowAffordance else { return fallback }
        return isOption ? affordance.alternateTitle : affordance.normalTitle
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
        if let monitor = flagsGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            flagsGlobalMonitor = nil
        }
        if let monitor = flagsLocalMonitor {
            NSEvent.removeMonitor(monitor)
            flagsLocalMonitor = nil
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
    private var newWindowBadge: NSImageView?
    /// Last known cursor position in Cocoa coordinates, fed by the drag pipeline. Cached so
    /// `update(...)` can reposition without falling back to `NSEvent.mouseLocation`, which is
    /// stale for Dock-icon drags whose mouse events are swallowed by the CGEventTap.
    private var lastCursorCocoa: CGPoint = .zero

    func show(title: String, at mouseLocation: CGPoint, showsNewWindowAffordance: Bool) {
        if feedbackWindow == nil {
            createFeedbackWindow()
        }

        guard let feedbackWindow else { return }

        applyContent(title: title, showsNewWindowAffordance: showsNewWindowAffordance)
        updatePosition(at: mouseLocation)
        feedbackWindow.alphaValue = 0
        feedbackWindow.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            feedbackWindow.animator().alphaValue = 1
        }
    }

    /// Live-update the preview's title and badge while the drag is in progress. Uses the
    /// last cursor position the drag pipeline reported via `updatePosition(at:)`.
    func update(title: String, showsNewWindowAffordance: Bool) {
        guard feedbackWindow != nil else { return }
        applyContent(title: title, showsNewWindowAffordance: showsNewWindowAffordance)
        updatePosition(at: lastCursorCocoa)
    }

    func updatePosition(at mouseLocation: CGPoint) {
        guard let feedbackWindow else { return }
        lastCursorCocoa = mouseLocation

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

    private func applyContent(title: String, showsNewWindowAffordance: Bool) {
        guard let feedbackWindow, let titleLabel else { return }

        titleLabel.stringValue = title
        titleLabel.sizeToFit()
        newWindowBadge?.isHidden = !showsNewWindowAffordance

        let padding: CGFloat = 16
        let badgeExtra: CGFloat = showsNewWindowAffordance ? 18 : 0
        let windowSize = NSSize(
            width: min(titleLabel.frame.width + padding * 2 + badgeExtra, 270),
            height: titleLabel.frame.height + padding
        )
        feedbackWindow.setContentSize(windowSize)
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

        let badge = NSImageView()
        badge.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "New window")
        badge.contentTintColor = .systemGreen
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true

        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = visualEffect

        let stackView = NSStackView(views: [iconView, badge, label])
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
            badge.widthAnchor.constraint(equalToConstant: 14),
            badge.heightAnchor.constraint(equalToConstant: 14),
        ])

        feedbackWindow = window
        titleLabel = label
        newWindowBadge = badge
    }
}
