import AppKit
import Carbon

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
    private let onDidCancelByUser: ((Payload) -> Void)?
    private let dragPreview = CursorDrivenDragPreview()

    /// The payload of the drag in flight, if any.
    private(set) var activePayload: Payload?
    private var dragGlobalMonitor: Any?
    private var dragLocalMonitor: Any?
    private var flagsGlobalMonitor: Any?
    private var flagsLocalMonitor: Any?
    private var escapeEventTap: EventTapController?
    private var newWindowAffordance: NewWindowAffordance?

    init(
        logPrefix: String,
        currentCursorAXProvider: @escaping () -> CGPoint?,
        onDidBeginDrag: @escaping (Payload) -> Void,
        onDidUpdateDrag: @escaping (CGPoint?) -> Void,
        onDidEndDrag: @escaping (Payload, CGPoint?) -> Void,
        onDidCancelByUser: ((Payload) -> Void)? = nil
    ) {
        self.logPrefix = logPrefix
        self.currentCursorAXProvider = currentCursorAXProvider
        self.onDidBeginDrag = onDidBeginDrag
        self.onDidUpdateDrag = onDidUpdateDrag
        self.onDidEndDrag = onDidEndDrag
        self.onDidCancelByUser = onDidCancelByUser
    }

    var isDragging: Bool {
        activePayload != nil
    }

    /// Starts a drag. The preview shows `image` when given (e.g. a snapshot thumbnail), otherwise a
    /// pill with `title`.
    func beginDrag(
        for payload: Payload,
        title: String,
        image: NSImage? = nil,
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
            image: image,
            at: initialCursorPointCocoa ?? NSEvent.mouseLocation,
            showsNewWindowAffordance: isOption
        )
        onDidBeginDrag(payload)

        if newWindowAffordance != nil {
            installFlagsMonitors()
        }

        installEscapeInterceptor()

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

    /// User pressed Esc while a drag was in flight. Called synchronously from the event-tap
    /// callback. Everything that has to close races against a pending mouse-up
    /// happens synchronously: `activePayload` is cleared so the NSEvent mouse monitor
    /// becomes a no-op, the preview is hidden, and `onDidCancelByUser` fires so owners can
    /// flip their own state (e.g. `DockClickInterceptor.cancelInProgressDrag()`) before
    /// the eventual mouse-up is delivered. Only monitor/tap teardown is deferred to the
    /// next main-runloop turn, so we never call `escapeEventTap.stop()` from inside
    /// the event-tap callback we are running on.
    func cancelDragByUser() {
        guard let payload = activePayload else { return }
        Logger.debug("\(logPrefix): drag cancelled by user (Escape)")
        activePayload = nil
        newWindowAffordance = nil
        dragPreview.hide()
        onDidCancelByUser?(payload)
        DispatchQueue.main.async { [weak self] in
            self?.tearDownMonitors()
        }
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

    /// Installs a CGEventTap (Input Monitoring) that swallows Escape while the drag is in
    /// flight, so the keystroke never reaches the frontmost app. `NSEvent` global monitors
    /// are observation-only and cannot consume events targeted at other apps, which is why
    /// a tap is required here.
    private func installEscapeInterceptor() {
        let tap = EventTapController(
            name: "\(logPrefix): Escape",
            events: [.keyDown],
            handler: { [weak self] type, event in
                guard type == .keyDown else { return .pass }

                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                guard keyCode == CGKeyCode(kVK_Escape) else { return .pass }

                self?.cancelDragByUser()
                return .swallow
            }
        )
        if tap.start() {
            escapeEventTap = tap
        }
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
        escapeEventTap?.stop()
        escapeEventTap = nil
    }

    deinit {
        tearDownMonitors()
    }
}

/// Floating drag preview that follows the cursor during cursor-driven drags: a pill with an icon and
/// title, or an image (e.g. a WinShot snapshot thumbnail) fitted into `maxImageSize`.
private final class CursorDrivenDragPreview {
    private static let maxImageSize = NSSize(width: 160, height: 100)

    private var feedbackWindow: NSWindow?
    private var titleLabel: NSTextField?
    private var newWindowBadge: NSImageView?
    private var pillStackView: NSStackView?
    private var imageView: NSImageView?
    /// Last known cursor position in Cocoa coordinates, fed by the drag pipeline. Cached so
    /// `update(...)` can reposition without falling back to `NSEvent.mouseLocation`, which is
    /// stale for Dock-icon drags whose mouse events are swallowed by the CGEventTap.
    private var lastCursorCocoa: CGPoint = .zero

    func show(title: String, image: NSImage?, at mouseLocation: CGPoint, showsNewWindowAffordance: Bool) {
        if feedbackWindow == nil {
            createFeedbackWindow()
        }

        guard let feedbackWindow else { return }

        if let image {
            applyImage(image)
        } else {
            applyContent(title: title, showsNewWindowAffordance: showsNewWindowAffordance)
        }
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

    /// Shows `image` scaled to fit `maxImageSize`, sizing the window to the scaled image.
    private func applyImage(_ image: NSImage) {
        guard let feedbackWindow, let imageView else { return }

        imageView.image = image
        imageView.isHidden = false
        pillStackView?.isHidden = true

        let maxSize = Self.maxImageSize
        let scale = min(maxSize.width / max(image.size.width, 1), maxSize.height / max(image.size.height, 1), 1)
        feedbackWindow.setContentSize(NSSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        ))
    }

    private func applyContent(title: String, showsNewWindowAffordance: Bool) {
        guard let feedbackWindow, let titleLabel else { return }

        imageView?.isHidden = true
        pillStackView?.isHidden = false
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
        // Sit above Launcher / DockMenu / CmdTab panels (all `.popUpMenu`) so the cursor-following
        // drag preview is never visually clipped behind them.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
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

        let previewImageView = NSImageView()
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.isHidden = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        // Let the window's content size (set in applyImage) win over the image's intrinsic size.
        previewImageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewImageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        visualEffect.addSubview(stackView)
        visualEffect.addSubview(previewImageView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -10),
            stackView.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            badge.widthAnchor.constraint(equalToConstant: 14),
            badge.heightAnchor.constraint(equalToConstant: 14),
            previewImageView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            previewImageView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        feedbackWindow = window
        titleLabel = label
        newWindowBadge = badge
        pillStackView = stackView
        imageView = previewImageView
    }
}
