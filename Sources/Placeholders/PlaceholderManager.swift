import Foundation
import AppKit
import QuartzCore

// MARK: - FirstClickButton

/// NSButton subclass that accepts first mouse clicks in non-activating panels.
/// Standard NSButton returns false for acceptsFirstMouse, which can cause
/// clicks to be ignored when the window is inactive.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

/// Delegate protocol for placeholder UI events.
protocol PlaceholderManagerDelegate: AnyObject {
    /// Called when a placeholder window is activated (clicked or double-clicked).
    func placeholderActivated(screenId: CGDirectDisplayID, zoneIndex: Int, isDoubleClick: Bool)

    /// Called when the close/put-away button is clicked.
    func placeholderCloseRequested(screenId: CGDirectDisplayID, zoneIndex: Int)

    /// Called when the search pill is clicked (opens Launcher).
    func placeholderSearchPillClicked(screenId: CGDirectDisplayID, zoneIndex: Int)

    /// Called when external content (files/URLs) is dropped on a placeholder.
    func placeholderReceivedExternalDrop(
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        items: [ExternalDropItem]
    )

    /// Returns the button mode (remove zone vs UnderCovers) for a placeholder.
    func placeholderButtonMode(screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderButtonMode
}

/// Creates and manages the UI for placeholder windows.
/// Placeholders are visual representations of empty tiling zones.
final class PlaceholderManager {
    private enum LayerName {
        static let panelSheen = "placeholder.panel.sheen"
        static let closeButtonBase = "placeholder.close.base"
        static let closeButtonSheen = "placeholder.close.sheen"
        static let closeButtonInnerRing = "placeholder.close.inner-ring"
        static let searchPillBase = "placeholder.search.base"
    }

    weak var delegate: PlaceholderManagerDelegate?

    init() {}

    /// Create a placeholder window for an empty zone.
    /// The returned PlaceholderWindow has no windowId - it is owned directly by the caller.
    func createPlaceholder(
        frame: CGRect,
        zoneIndex: Int,
        on screen: ScreenDescriptor
    ) -> PlaceholderWindow {
        let cocoaFrame = screen.screenToCocoa(frame)

        let panel = PlaceholderPanel(
            contentRect: cocoaFrame,
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.styleMask.insert(.fullSizeContentView)
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isMovable = false
        panel.minSize = NSSize(width: 120, height: 120)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // Create content view with placeholder UI
        let contentView = PlaceholderContentView(
            frame: NSRect(origin: .zero, size: frame.size),
            manager: self,
            screenId: screen.displayId,
            zoneIndex: zoneIndex
        )
        if let layer = contentView.layer {
            applyPanelGlassStyle(to: layer)
        }

        // Create close/put-away button
        let buttonSize: CGFloat = 36
        let closeButton = FirstClickButton(title: "×", target: self, action: #selector(handlePlaceholderClose(_:)))
        closeButton.frame = NSRect(x: 16, y: max(frame.height - buttonSize - 16, 16), width: buttonSize, height: buttonSize)
        closeButton.setButtonType(.momentaryChange)
        closeButton.bezelStyle = .shadowlessSquare
        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.wantsLayer = true
        applyCloseButtonGlassStyle(closeButton, buttonSize: buttonSize)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]

        contentView.addSubview(closeButton)
        contentView.attachCloseButton(closeButton)

        // Create search pill (opens Launcher on click)
        let pillPreferredWidth: CGFloat = 180
        let pillHeight: CGFloat = buttonSize
        let pillY = closeButton.frame.origin.y
        let iconLeftPadding: CGFloat = 14

        let searchPill = FirstClickButton(frame: NSRect(x: 0, y: pillY, width: pillPreferredWidth, height: pillHeight))
        searchPill.setButtonType(.momentaryChange)
        searchPill.bezelStyle = .shadowlessSquare
        searchPill.isBordered = false
        searchPill.focusRingType = .none
        searchPill.wantsLayer = true
        searchPill.title = ""
        searchPill.image = nil

        applySearchPillGlassStyle(searchPill, pillHeight: pillHeight)

        // Add icon as a separate image view
        var iconView: NSImageView?
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if let icon = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(symbolConfig) {
            let iconSize: CGFloat = 18
            let iconImageView = NSImageView(frame: NSRect(
                x: iconLeftPadding,
                y: (pillHeight - iconSize) / 2,
                width: iconSize,
                height: iconSize
            ))
            iconImageView.image = icon
            iconImageView.contentTintColor = NSColor.white.withAlphaComponent(0.7)
            iconImageView.imageScaling = .scaleProportionallyUpOrDown
            iconImageView.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
            searchPill.addSubview(iconImageView)
            iconView = iconImageView
        }

        searchPill.autoresizingMask = [.minYMargin]
        searchPill.target = self
        searchPill.action = #selector(handleSearchPillClick(_:))
        searchPill.sendAction(on: .leftMouseDown)

        contentView.addSubview(searchPill)
        contentView.attachSearchPill(searchPill, iconView: iconView)

        panel.contentView = contentView
        contentView.autoresizingMask = [.width, .height]

        let placeholder = PlaceholderWindow(
            panel: panel,
            screenDisplayId: screen.displayId,
            zoneIndex: zoneIndex
        )

        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Created placeholder for zone \(zoneIndex) on screen \(screenIndex)")

        return placeholder
    }

    private func applyPanelGlassStyle(to layer: CALayer) {
        layer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.24).cgColor
        layer.cornerRadius = 12
        layer.borderWidth = 1.5
        layer.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        layer.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
        layer.shadowOpacity = 1.0
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: -2)
        if #available(macOS 10.15, *) {
            layer.cornerCurve = .continuous
        }

        removeSublayers(named: LayerName.panelSheen, from: layer)

        let sheen = CAGradientLayer()
        sheen.name = LayerName.panelSheen
        sheen.frame = layer.bounds
        sheen.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        sheen.cornerRadius = layer.cornerRadius
        sheen.colors = [
            NSColor.white.withAlphaComponent(0.25).cgColor,
            NSColor.white.withAlphaComponent(0.07).cgColor,
            NSColor.clear.cgColor
        ]
        sheen.locations = [0.0, 0.25, 1.0]
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.0)
        layer.insertSublayer(sheen, at: 0)
    }

    private func applyCloseButtonGlassStyle(_ button: NSButton, buttonSize: CGFloat) {
        guard let layer = button.layer else { return }
        layer.masksToBounds = false
        layer.cornerRadius = buttonSize / 2
        layer.borderWidth = 1.1
        layer.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor
        layer.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer.shadowOpacity = 1.0
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.backgroundColor = NSColor.clear.cgColor

        removeSublayers(named: LayerName.closeButtonBase, from: layer)
        removeSublayers(named: LayerName.closeButtonSheen, from: layer)
        removeSublayers(named: LayerName.closeButtonInnerRing, from: layer)

        let baseGradient = CAGradientLayer()
        baseGradient.name = LayerName.closeButtonBase
        baseGradient.frame = layer.bounds
        baseGradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        baseGradient.cornerRadius = buttonSize / 2
        baseGradient.colors = [
            NSColor.systemBlue.withAlphaComponent(0.56).cgColor,
            NSColor.systemBlue.withAlphaComponent(0.28).cgColor
        ]
        baseGradient.startPoint = CGPoint(x: 0.2, y: 1.0)
        baseGradient.endPoint = CGPoint(x: 0.8, y: 0.0)
        layer.insertSublayer(baseGradient, at: 0)

        let sheen = CAGradientLayer()
        sheen.name = LayerName.closeButtonSheen
        sheen.frame = layer.bounds.insetBy(dx: 1, dy: 1)
        sheen.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        sheen.cornerRadius = max(0, buttonSize / 2 - 1)
        sheen.colors = [
            NSColor.white.withAlphaComponent(0.24).cgColor,
            NSColor.white.withAlphaComponent(0.08).cgColor,
            NSColor.clear.cgColor
        ]
        sheen.locations = [0.0, 0.35, 1.0]
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.0)
        layer.addSublayer(sheen)

        let innerRing = CAShapeLayer()
        innerRing.name = LayerName.closeButtonInnerRing
        innerRing.frame = layer.bounds
        innerRing.path = CGPath(
            ellipseIn: layer.bounds.insetBy(dx: 1.4, dy: 1.4),
            transform: nil
        )
        innerRing.fillColor = NSColor.clear.cgColor
        innerRing.strokeColor = NSColor.white.withAlphaComponent(0.2).cgColor
        innerRing.lineWidth = 1
        layer.addSublayer(innerRing)
    }

    private func applySearchPillGlassStyle(_ pill: NSButton, pillHeight: CGFloat) {
        guard let layer = pill.layer else { return }
        layer.cornerRadius = pillHeight / 2
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer.backgroundColor = NSColor.clear.cgColor

        removeSublayers(named: LayerName.searchPillBase, from: layer)

        let gradient = CAGradientLayer()
        gradient.name = LayerName.searchPillBase
        gradient.frame = layer.bounds
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        gradient.cornerRadius = pillHeight / 2
        gradient.colors = [
            NSColor.white.withAlphaComponent(0.36).cgColor,
            NSColor.white.withAlphaComponent(0.1).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0.1, y: 1.0)
        gradient.endPoint = CGPoint(x: 0.9, y: 0.0)
        layer.insertSublayer(gradient, at: 0)
    }

    private func removeSublayers(named layerName: String, from layer: CALayer) {
        layer.sublayers?.filter { $0.name == layerName }.forEach { $0.removeFromSuperlayer() }
    }

    // MARK: - Button Actions

    @objc private func handlePlaceholderClose(_ sender: NSButton) {
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

    @objc private func handleSearchPillClick(_ sender: NSButton) {
        guard let window = sender.window,
              let contentView = window.contentView as? PlaceholderContentView else {
            return
        }
        let screenIndex = ScreenContextStore.screenIndex(for: contentView.screenId) ?? Int(contentView.screenId)
        Logger.debug("Placeholder search pill clicked for zone \(contentView.zoneIndex) on screen \(screenIndex)")
        delegate?.placeholderSearchPillClicked(screenId: contentView.screenId, zoneIndex: contentView.zoneIndex)
    }

    // MARK: - Internal Handlers

    func handlePlaceholderActivation(screenId: CGDirectDisplayID, zoneIndex: Int, isDoubleClick: Bool) {
        let screenIndex = ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Placeholder activated for zone \(zoneIndex) on screen \(screenIndex) (doubleClick: \(isDoubleClick))")
        delegate?.placeholderActivated(screenId: screenId, zoneIndex: zoneIndex, isDoubleClick: isDoubleClick)
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

    func buttonMode(for screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderButtonMode {
        delegate?.placeholderButtonMode(screenId: screenId, zoneIndex: zoneIndex) ?? .removeZone
    }
}

// MARK: - PlaceholderContentView

/// Content view for placeholder windows, using the new PlaceholderManager.
final class PlaceholderContentView: NSView {
    weak var manager: PlaceholderManager?
    private(set) var screenId: CGDirectDisplayID
    private(set) var zoneIndex: Int
    private var closeButton: NSButton?
    private var searchPill: NSButton?
    private var searchPillIconView: NSImageView?
    private var isDropHighlighted = false {
        didSet {
            if isDropHighlighted != oldValue {
                updateBorderAppearance()
            }
        }
    }
    var isTargeted: Bool = false {
        didSet {
            if isTargeted != oldValue {
                updateBorderAppearance()
            }
        }
    }
    private let normalBorderColor = NSColor.white.withAlphaComponent(0.45).cgColor
    private let highlightedBorderColor = NSColor.systemBlue.withAlphaComponent(0.72).cgColor
    private let targetedBorderColor = NSColor.systemBlue.withAlphaComponent(0.50).cgColor

    init(frame: NSRect, manager: PlaceholderManager, screenId: CGDirectDisplayID, zoneIndex: Int) {
        self.manager = manager
        self.screenId = screenId
        self.zoneIndex = zoneIndex
        super.init(frame: frame)
        wantsLayer = true
        ForceClickSuppression.apply(to: self)
        registerForDraggedTypes(ExternalDropParser.registeredPasteboardTypes)
        updateBorderAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)

        // Don't trigger zone activation if clicking on the close/UnderCovers button
        let isOnCloseButton = closeButton?.frame.contains(locationInView) == true

        if !isOnCloseButton {
            manager?.handlePlaceholderActivation(screenId: screenId, zoneIndex: zoneIndex, isDoubleClick: event.clickCount >= 2)
        }
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
        updateSearchPillLayout()
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
        return manager?.handlePlaceholderExternalDrop(
            screenId: screenId,
            zoneIndex: zoneIndex,
            draggingInfo: sender
        ) ?? false
    }

    func attachCloseButton(_ button: NSButton) {
        closeButton = button
        updateButtonStyle()
    }

    func attachSearchPill(_ pill: NSButton, iconView: NSImageView?) {
        searchPill = pill
        searchPillIconView = iconView
        updateSearchPillLayout()
    }

    private func updateButtonStyle() {
        guard let manager, let closeButton else { return }

        let mode = manager.buttonMode(for: screenId, zoneIndex: zoneIndex)
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
        if isDropHighlighted {
            layer.borderWidth = 2.5
            layer.borderColor = highlightedBorderColor
        } else if isTargeted {
            layer.borderWidth = 3.5
            layer.borderColor = targetedBorderColor
        } else {
            layer.borderWidth = 1.5
            layer.borderColor = normalBorderColor
        }
    }

    /// Flashes a vivid blue border that animates to the resting state, providing
    /// immediate visual feedback for a Control+Command click.
    func flashBorder() {
        guard let layer = layer else { return }
        let restingColor = isTargeted ? targetedBorderColor : normalBorderColor
        let restingWidth: CGFloat = isTargeted ? 3.5 : 1.5

        let colorAnim = CABasicAnimation(keyPath: "borderColor")
        colorAnim.fromValue = NSColor.systemBlue.withAlphaComponent(0.88).cgColor
        colorAnim.toValue = restingColor
        colorAnim.duration = 0.45
        colorAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(colorAnim, forKey: "borderColorFlash")

        let widthAnim = CABasicAnimation(keyPath: "borderWidth")
        widthAnim.fromValue = CGFloat(5.5)
        widthAnim.toValue = restingWidth
        widthAnim.duration = 0.45
        widthAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(widthAnim, forKey: "borderWidthFlash")
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateSearchPillLayout()
    }

    private func updateSearchPillLayout() {
        guard let searchPill else { return }

        let pillHeight = searchPill.frame.height
        let desiredPillWidth: CGFloat = 180
        let edgePadding: CGFloat = 16
        let closeButtonGap: CGFloat = 2

        let boundsWidth = bounds.width
        let leftClearance = max(edgePadding, (closeButton?.frame.maxX ?? edgePadding) + closeButtonGap)

        let maxWidthByEdges = max(0, boundsWidth - 2 * edgePadding)
        let maxWidthCenteredByCloseButton = max(0, boundsWidth - 2 * leftClearance)
        let maxCenteredWidth = min(desiredPillWidth, maxWidthByEdges, maxWidthCenteredByCloseButton)

        let pillWidth: CGFloat
        let pillX: CGFloat
        if maxCenteredWidth > 0 {
            pillWidth = maxCenteredWidth
            pillX = (boundsWidth - pillWidth) / 2
        } else {
            let availableWidth = max(0, (boundsWidth - edgePadding) - leftClearance)
            pillWidth = min(desiredPillWidth, availableWidth)
            pillX = leftClearance
        }

        let pillY = closeButton?.frame.origin.y ?? searchPill.frame.origin.y
        searchPill.frame = NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)

        if let layer = searchPill.layer {
            layer.cornerRadius = min(pillHeight / 2, pillWidth / 2)
        }

        if let iconView = searchPillIconView {
            let iconSize = iconView.frame.width
            let iconLeftPadding: CGFloat = 14
            let iconX: CGFloat
            if pillWidth < iconLeftPadding + iconSize {
                iconX = max(0, (pillWidth - iconSize) / 2)
            } else {
                iconX = iconLeftPadding
            }
            iconView.frame.origin.x = iconX
            iconView.frame.origin.y = max(0, (pillHeight - iconSize) / 2)
        }
    }
}
