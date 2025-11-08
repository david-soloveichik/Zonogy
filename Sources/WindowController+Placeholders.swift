import Foundation
import AppKit
import ApplicationServices

/// Test-window utilities and placeholder window rendering for WindowController.
final class PlaceholderContentView: NSView {
    weak var controller: WindowController?
    private(set) var screenId: CGDirectDisplayID
    private(set) var zoneIndex: Int

    init(frame: NSRect, controller: WindowController, screenId: CGDirectDisplayID, zoneIndex: Int) {
        self.controller = controller
        self.screenId = screenId
        self.zoneIndex = zoneIndex
        super.init(frame: frame)
        wantsLayer = true
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
    }

    override func layout() {
        super.layout()
        if let layer = layer {
            layer.cornerRadius = 12
        }
    }
}

extension WindowController {
    /// Create a new test window with a title
    func createTestWindow(frame: CGRect) -> ManagedWindow {
        let windowId = windowRegistry.allocateIdentifier()

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "test \(windowId)"
        window.isReleasedWhenClosed = false

        // Set up delegate to handle window events
        let windowDelegate = ManagedWindowDelegate(windowId: windowId, controller: self)
        window.delegate = windowDelegate
        windowDelegates[windowId] = windowDelegate  // Retain the delegate

        let managed = ManagedWindow(
            windowId: windowId,
            backing: .appKit(window),
            isPlaceholder: false
        )
        windowRegistry.insert(managed)

        Logger.debug("Created test window \(windowId)")
        return managed
    }

    /// Create a placeholder window for an empty zone
    func createPlaceholderWindow(frame: CGRect, zoneIndex: Int, on screen: ScreenDescriptor) -> ManagedWindow {
        let windowId = windowRegistry.allocateIdentifier()

        let cocoaFrame = screen.screenToCocoa(frame)
        let window = NSWindow(
            contentRect: cocoaFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.styleMask.insert(.fullSizeContentView)
        window.isReleasedWhenClosed = false
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

        // Create a custom blue "x" close button that matches the spec
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
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold)
        ]
        let attributedTitle = NSAttributedString(string: "×", attributes: titleAttributes)
        closeButton.attributedTitle = attributedTitle
        closeButton.attributedAlternateTitle = attributedTitle
        closeButton.target = self
        closeButton.action = #selector(handlePlaceholderClose(_:))
        closeButton.tag = zoneIndex
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]

        contentView.addSubview(closeButton)
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

        if let closeButton = window.contentView?.subviews.compactMap({ $0 as? NSButton }).first {
            closeButton.tag = zoneIndex
        }

        if let contentView = window.contentView as? PlaceholderContentView {
            contentView.update(screenId: screenId, zoneIndex: zoneIndex)
        }
    }

    func handlePlaceholderActivation(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Placeholder activated for zone \(zoneIndex) on screen \(screenIndex)")
        delegate?.placeholderActivated(screenId: screenId, zoneIndex: zoneIndex)
    }

    @objc func handlePlaceholderClose(_ sender: NSButton) {
        let zoneIndex = sender.tag
        let screenId: CGDirectDisplayID?
        if let window = sender.window {
            screenId = windowRegistry.first(where: { managed in
                managed.isPlaceholder && managed.appKitWindow === window
            })?.screenDisplayId
        } else {
            screenId = nil
        }

        let screenIndex = screenId.flatMap { ScreenContextStore.screenIndex(for: $0) } ?? (screenId.map { Int($0) } ?? 0)
        Logger.debug("Placeholder close button clicked for zone \(zoneIndex) on screen \(screenIndex)")
        if let screenId {
            delegate?.placeholderCloseRequested(screenId: screenId, zoneIndex: zoneIndex)
        }
    }
}
