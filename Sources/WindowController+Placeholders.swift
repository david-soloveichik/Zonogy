import Foundation
import AppKit
import ApplicationServices

/// Display mode for the blue placeholder button (normal close vs UnderCovers put-away).
enum PlaceholderButtonMode {
    case removeZone
    case underCovers
}

/// Placeholder windows should never steal keyboard focus from real apps.
/// Use a non-activating panel subclass so clicks don't bring Zonogy forward.
final class PlaceholderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        // Panels can be ordered front for visibility without becoming key.
        orderFront(sender)
    }
}

/// Placeholder window rendering for WindowController.
final class PlaceholderContentView: NSView {
    weak var controller: WindowController?
    private(set) var screenId: CGDirectDisplayID
    private(set) var zoneIndex: Int
    private var closeButton: NSButton?
    private var isDropHighlighted = false {
        didSet {
            if isDropHighlighted != oldValue {
                updateBorderAppearance()
            }
        }
    }
    private let normalBorderColor = NSColor.white.withAlphaComponent(0.35).cgColor
    private let highlightedBorderColor = NSColor.systemBlue.withAlphaComponent(0.65).cgColor

    init(frame: NSRect, controller: WindowController, screenId: CGDirectDisplayID, zoneIndex: Int) {
        self.controller = controller
        self.screenId = screenId
        self.zoneIndex = zoneIndex
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes(ExternalDropParser.registeredPasteboardTypes)
        updateBorderAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        controller?.handlePlaceholderActivation(screenId: screenId, zoneIndex: zoneIndex)
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    func update(screenId: CGDirectDisplayID, zoneIndex: Int) {
        self.screenId = screenId
        self.zoneIndex = zoneIndex
        updateButtonStyle()
    }

    override func layout() {
        super.layout()
        if let layer = layer {
            layer.cornerRadius = 12
            updateBorderAppearance()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ExternalDropParser.canAccept(sender) else {
            return []
        }
        isDropHighlighted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return isDropHighlighted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropHighlighted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropHighlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return ExternalDropParser.canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropHighlighted = false
        return controller?.handlePlaceholderExternalDrop(
            screenId: screenId,
            zoneIndex: zoneIndex,
            draggingInfo: sender
        ) ?? false
    }

    func attachCloseButton(_ button: NSButton) {
        closeButton = button
        updateButtonStyle()
    }

    private func updateButtonStyle() {
        guard let controller, let closeButton else { return }

        let mode = controller.placeholderButtonModeProvider?(screenId, zoneIndex) ?? .removeZone
        let symbol: String
        let baselineOffset: CGFloat
        switch mode {
        case .removeZone:
            symbol = "×"
            baselineOffset = 1.0
        case .underCovers:
            symbol = "⌄"
            baselineOffset = 4.0
        }

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .baselineOffset: baselineOffset
        ]
        let attributedTitle = NSAttributedString(string: symbol, attributes: titleAttributes)
        closeButton.attributedTitle = attributedTitle
        closeButton.attributedAlternateTitle = attributedTitle
    }

    private func updateBorderAppearance() {
        guard let layer = layer else { return }
        layer.borderWidth = isDropHighlighted ? 3 : 2
        layer.borderColor = isDropHighlighted ? highlightedBorderColor : normalBorderColor
    }
}

extension WindowController {
    /// Create a placeholder window for an empty zone
    func createPlaceholderWindow(frame: CGRect, zoneIndex: Int, on screen: ScreenDescriptor) -> ManagedWindow {
        let windowId = windowRegistry.allocateIdentifier()

        let cocoaFrame = screen.screenToCocoa(frame)
        let window = PlaceholderPanel(
            contentRect: cocoaFrame,
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = false
        window.becomesKeyOnlyIfNeeded = false
        window.styleMask.insert(.fullSizeContentView)
        window.isReleasedWhenClosed = false
        // AltTab filters out any window whose CoreGraphics level is not `CGWindowLevelForKey(.normalWindow)`. 
        // We don't want it show our placeholder windows, so we may want to use: window.level = .floating
        // But then placeholder windows always appear over other windows, which we don't want
        window.level = .normal
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.minSize = NSSize(width: 120, height: 120)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Create a custom content view with a close button
        let contentView = PlaceholderContentView(
            frame: NSRect(origin: .zero, size: frame.size),
            controller: self,
            screenId: screen.displayId,
            zoneIndex: zoneIndex
        )
        if let layer = contentView.layer {
            layer.backgroundColor = NSColor(white: 0.9, alpha: 0.3).cgColor
            layer.cornerRadius = 12
            layer.borderWidth = 2
            layer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            if #available(macOS 10.15, *) {
                layer.cornerCurve = .continuous
            }
        }

        // Create a custom blue close/put-away button that matches the spec
        let buttonSize: CGFloat = 36
        let closeButton = NSButton(title: "×", target: self, action: #selector(handlePlaceholderClose(_:)))
        closeButton.frame = NSRect(x: 16, y: max(frame.height - buttonSize - 16, 16), width: buttonSize, height: buttonSize)
        closeButton.setButtonType(.momentaryChange)
        closeButton.bezelStyle = .shadowlessSquare
        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.wantsLayer = true
        closeButton.alphaValue = 0.9
        if let layer = closeButton.layer {
            layer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
            layer.cornerRadius = buttonSize / 2
            layer.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
            layer.shadowOpacity = 0.25
            layer.shadowRadius = 3
            layer.shadowOffset = CGSize(width: 0, height: -1)
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        }
        // Title is driven by PlaceholderContentView based on button mode (remove vs UnderCovers)
        closeButton.target = self
        closeButton.action = #selector(handlePlaceholderClose(_:))
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]

        contentView.addSubview(closeButton)
        contentView.attachCloseButton(closeButton)

        // Create search pill (opens Launcher on click)
        let pillWidth: CGFloat = 90
        let pillHeight: CGFloat = buttonSize
        let pillX = (frame.width - pillWidth) / 2
        let pillY = closeButton.frame.origin.y
        let iconLeftPadding: CGFloat = 14

        // Use a button as the container for the pill
        let searchPill = NSButton(frame: NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight))
        searchPill.setButtonType(.momentaryChange)
        searchPill.bezelStyle = .shadowlessSquare
        searchPill.isBordered = false
        searchPill.focusRingType = .none
        searchPill.wantsLayer = true
        searchPill.alphaValue = 0.9
        searchPill.title = ""
        searchPill.image = nil

        if let layer = searchPill.layer {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
            layer.cornerRadius = pillHeight / 2
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            layer.shadowColor = NSColor.black.withAlphaComponent(0.15).cgColor
            layer.shadowOpacity = 0.15
            layer.shadowRadius = 2
            layer.shadowOffset = CGSize(width: 0, height: -1)
        }

        // Add icon as a separate image view with left padding
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if let icon = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(symbolConfig) {
            let iconSize: CGFloat = 18
            let iconView = NSImageView(frame: NSRect(
                x: iconLeftPadding,
                y: (pillHeight - iconSize) / 2,
                width: iconSize,
                height: iconSize
            ))
            iconView.image = icon
            iconView.contentTintColor = NSColor.white.withAlphaComponent(0.7)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
            searchPill.addSubview(iconView)
        }

        searchPill.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        searchPill.target = self
        searchPill.action = #selector(handleSearchPillClick(_:))
        searchPill.sendAction(on: .leftMouseDown)

        contentView.addSubview(searchPill)

        window.contentView = contentView
        contentView.autoresizingMask = [.width, .height]

        // Set up delegate to track resize events
        let windowDelegate = ManagedWindowDelegate(windowId: windowId, controller: self)
        window.delegate = windowDelegate
        windowDelegates[windowId] = windowDelegate

        let managed = ManagedWindow(
            windowId: windowId,
            backing: .appKit(window),
            isPlaceholder: true
        )
        managed.screenDisplayId = screen.displayId
        managed.zoneIndex = zoneIndex
        windowRegistry.insert(managed)

        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Created placeholder window \(windowId) for zone \(zoneIndex) on screen \(screenIndex)")
        return managed
    }

    func refreshPlaceholderMetadata(_ placeholder: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int) {
        guard placeholder.isPlaceholder,
              let window = placeholder.appKitWindow else {
            return
        }

        placeholder.screenDisplayId = screenId
        placeholder.zoneIndex = zoneIndex

        if let contentView = window.contentView as? PlaceholderContentView {
            contentView.update(screenId: screenId, zoneIndex: zoneIndex)
        }
    }

    func handlePlaceholderActivation(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Placeholder activated for zone \(zoneIndex) on screen \(screenIndex)")
        delegate?.placeholderActivated(screenId: screenId, zoneIndex: zoneIndex)
    }

    func handlePlaceholderDoubleClick(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Placeholder double-clicked for zone \(zoneIndex) on screen \(screenIndex)")
        delegate?.placeholderDoubleClicked(screenId: screenId, zoneIndex: zoneIndex)
    }

    @objc func handleSearchPillClick(_ sender: NSButton) {
        guard let window = sender.window,
              let contentView = window.contentView as? PlaceholderContentView else {
            return
        }
        // Target the zone first, then open the launcher
        handlePlaceholderActivation(screenId: contentView.screenId, zoneIndex: contentView.zoneIndex)
        handlePlaceholderDoubleClick(screenId: contentView.screenId, zoneIndex: contentView.zoneIndex)
    }

    @objc func handlePlaceholderClose(_ sender: NSButton) {
        // Get the zone information from the PlaceholderContentView which stores it directly
        guard let window = sender.window,
              let contentView = window.contentView as? PlaceholderContentView else {
            Logger.debug("Could not find PlaceholderContentView for close button")
            return
        }

        let screenId = contentView.screenId
        let zoneIndex = contentView.zoneIndex

        let screenIndex = ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Placeholder close button clicked for zone \(zoneIndex) on screen \(screenIndex)")
        delegate?.placeholderCloseRequested(screenId: screenId, zoneIndex: zoneIndex)
    }

    func handlePlaceholderExternalDrop(
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        draggingInfo: NSDraggingInfo
    ) -> Bool {
        guard let payload = ExternalDropParser.payload(from: draggingInfo) else {
            return false
        }
        delegate?.placeholderReceivedExternalDrop(
            screenId: screenId,
            zoneIndex: zoneIndex,
            items: payload.items
        )
        return true
    }
}
