import Foundation
import AppKit

/// Encapsulates AppKit window creation and manipulation
class WindowController {
    private var nextWindowId = 1
    private var managedWindows: [Int: ManagedWindow] = [:]
    private var windowDelegates: [Int: ManagedWindowDelegate] = [:]
    weak var delegate: WindowControllerDelegate?

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
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.backgroundColor = NSColor(white: 0.9, alpha: 0.3)
        window.isOpaque = false

        // Create a custom content view with a close button
        let contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.wantsLayer = true

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

        contentView.addSubview(closeButton)
        window.contentView = contentView

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
}
