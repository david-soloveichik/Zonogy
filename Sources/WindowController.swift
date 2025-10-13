import Foundation
import AppKit

struct PlaceholderResizeAxes: OptionSet {
    let rawValue: Int

    static let horizontal = PlaceholderResizeAxes(rawValue: 1 << 0)
    static let vertical = PlaceholderResizeAxes(rawValue: 1 << 1)
}

/// Encapsulates AppKit window creation and manipulation
class WindowController {
    private var nextWindowId = 1
    private var managedWindows: [Int: ManagedWindow] = [:]
    private var windowDelegates: [Int: ManagedWindowDelegate] = [:]
    weak var delegate: WindowControllerDelegate?
    private var currentDraggingWindowId: Int?
    private var mouseUpMonitor: Any?
    private var mouseUpGlobalMonitor: Any?
    private var resizingWindowId: Int?

    init() {
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.handleMouseUp()
            return event
        }
        mouseUpGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.handleMouseUp()
        }
    }

    deinit {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseUpGlobalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Create a new test window with a title
    func createTestWindow(frame: CGRect) -> ManagedWindow {
        let windowId = nextWindowId
        nextWindowId += 1

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

        let managed = ManagedWindow(windowId: windowId, window: window, isPlaceholder: false)
        managedWindows[windowId] = managed

        Logger.debug("Created test window \(windowId)")
        return managed
    }

    /// Create a placeholder window for an empty zone
    func createPlaceholderWindow(frame: CGRect, zoneIndex: Int) -> ManagedWindow {
        let windowId = nextWindowId
        nextWindowId += 1

        let window = NSWindow(
            contentRect: frame,
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
        let contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.wantsLayer = true
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

        let managed = ManagedWindow(windowId: windowId, window: window, isPlaceholder: true)
        managedWindows[windowId] = managed

        Logger.debug("Created placeholder window \(windowId) for zone \(zoneIndex)")
        return managed
    }

    @objc private func handlePlaceholderClose(_ sender: NSButton) {
        let zoneIndex = sender.tag
        Logger.debug("Placeholder close button clicked for zone \(zoneIndex)")
        delegate?.placeholderCloseRequested(zoneIndex: zoneIndex)
    }

    /// Get a managed window by ID
    func window(withId windowId: Int) -> ManagedWindow? {
        return managedWindows[windowId]
    }

    /// Show a window at the specified frame
    func showWindow(_ managedWindow: ManagedWindow, at frame: CGRect) {
        managedWindow.window.setFrame(frame, display: true)
        managedWindow.window.orderFront(nil)
        Logger.debug("Showed window \(managedWindow.windowId) at frame \(frame)")
    }

    /// Minimize a window
    func minimizeWindow(_ managedWindow: ManagedWindow) {
        managedWindow.window.miniaturize(nil)
        Logger.debug("Minimized window \(managedWindow.windowId)")
    }

    /// Unminimize a window
    func unminimizeWindow(_ managedWindow: ManagedWindow) {
        managedWindow.window.deminiaturize(nil)
        Logger.debug("Unminimized window \(managedWindow.windowId)")
    }

    /// Close a window
    func closeWindow(_ managedWindow: ManagedWindow) {
        managedWindow.window.close()
        managedWindows.removeValue(forKey: managedWindow.windowId)
        windowDelegates.removeValue(forKey: managedWindow.windowId)
        Logger.debug("Closed window \(managedWindow.windowId)")
    }

    /// Resize and reposition a window to match a frame
    func moveWindow(_ managedWindow: ManagedWindow, to frame: CGRect) {
        managedWindow.window.setFrame(frame, display: true, animate: false)
        Logger.debug("Moved window \(managedWindow.windowId) to frame \(frame)")
    }

    func constrainedPlaceholderSize(for windowId: Int, proposedSize: NSSize, currentSize: NSSize) -> NSSize {
        guard let managed = managedWindows[windowId],
              managed.isPlaceholder,
              let zoneIndex = managed.zoneIndex else {
            return proposedSize
        }

        let allowedAxes = delegate?.placeholderAllowedResizeAxes(zoneIndex: zoneIndex) ?? []
        var size = proposedSize

        if !allowedAxes.contains(.horizontal) {
            size.width = currentSize.width
        }
        if !allowedAxes.contains(.vertical) {
            size.height = currentSize.height
        }

        return size
    }

    private func handleMouseUp() {
        guard let windowId = currentDraggingWindowId else {
            return
        }
        currentDraggingWindowId = nil

        guard let managed = managedWindows[windowId], !managed.isPlaceholder else {
            return
        }

        Logger.debug("Finished dragging window \(windowId), requesting snap back")
        delegate?.windowManualMoveDidEnd(windowId: windowId, frame: managed.actualFrame)
    }

    /// Get all managed windows
    var allWindows: [ManagedWindow] {
        return Array(managedWindows.values)
    }
}

/// Delegate protocol for window controller events
protocol WindowControllerDelegate: AnyObject {
    func placeholderCloseRequested(zoneIndex: Int)
    func windowWillClose(windowId: Int)
    func windowDidMiniaturize(windowId: Int)
    func windowDidDeminiaturize(windowId: Int)
    func placeholderLiveResizeDidBegin(zoneIndex: Int)
    func placeholderLiveResized(zoneIndex: Int, to frame: CGRect)
    func placeholderLiveResizeDidEnd(zoneIndex: Int, to frame: CGRect)
    func placeholderAllowedResizeAxes(zoneIndex: Int) -> PlaceholderResizeAxes
    func windowManualResizeDidEnd(windowId: Int, frame: CGRect)
    func windowManualMoveDidEnd(windowId: Int, frame: CGRect)
}

/// NSWindowDelegate for tracking window events
class ManagedWindowDelegate: NSObject, NSWindowDelegate {
    let windowId: Int
    weak var controller: WindowController?

    init(windowId: Int, controller: WindowController) {
        self.windowId = windowId
        self.controller = controller
    }

    func windowWillClose(_ notification: Notification) {
        controller?.delegate?.windowWillClose(windowId: windowId)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        controller?.delegate?.windowDidMiniaturize(windowId: windowId)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        controller?.delegate?.windowDidDeminiaturize(windowId: windowId)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        controller?.windowWillStartLiveResize(windowId: windowId)
    }

    func windowDidResize(_ notification: Notification) {
        controller?.windowDidResize(windowId: windowId)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        controller?.windowDidEndLiveResize(windowId: windowId)
    }

    func windowWillMove(_ notification: Notification) {
        controller?.windowWillMove(windowId: windowId)
    }

    func windowDidMove(_ notification: Notification) {
        controller?.windowDidMove(windowId: windowId)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        return controller?.constrainedPlaceholderSize(
            for: windowId,
            proposedSize: frameSize,
            currentSize: sender.frame.size
        ) ?? frameSize
    }
}

extension WindowController {
    func windowWillStartLiveResize(windowId: Int) {
        guard let managed = managedWindows[windowId] else {
            return
        }

        if managed.isPlaceholder {
            guard let zoneIndex = managed.zoneIndex else {
                return
            }
            delegate?.placeholderLiveResizeDidBegin(zoneIndex: zoneIndex)
        } else {
            resizingWindowId = windowId
        }
    }

    func windowDidResize(windowId: Int) {
        guard let managed = managedWindows[windowId] else {
            return
        }

        if managed.isPlaceholder {
            guard let zoneIndex = managed.zoneIndex else {
                return
            }
            delegate?.placeholderLiveResized(zoneIndex: zoneIndex, to: managed.actualFrame)
        }
    }

    func windowDidEndLiveResize(windowId: Int) {
        guard let managed = managedWindows[windowId] else {
            return
        }

        if managed.isPlaceholder {
            guard let zoneIndex = managed.zoneIndex else {
                return
            }
            delegate?.placeholderLiveResizeDidEnd(zoneIndex: zoneIndex, to: managed.actualFrame)
        } else {
            guard resizingWindowId == windowId else {
                return
            }
            resizingWindowId = nil
            Logger.debug("Finished resizing window \(windowId), notifying delegate")
            delegate?.windowManualResizeDidEnd(windowId: windowId, frame: managed.actualFrame)
        }
    }

    func windowWillMove(windowId: Int) {
        guard let managed = managedWindows[windowId], !managed.isPlaceholder else {
            return
        }

        currentDraggingWindowId = windowId
        Logger.debug("User began dragging window \(windowId)")
    }

    func windowDidMove(windowId: Int) {
        guard managedWindows[windowId] != nil else {
            return
        }
        // Drag completion handling occurs on mouse-up.
    }
}
