import Foundation
import AppKit
import ApplicationServices

// Bridge to private API for getting window ID
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
private let axWindowNumberAttribute: CFString = "AXWindowNumber" as CFString
private let axCloseAction: CFString = "AXClose" as CFString
private let axDestroyedNotification = kAXUIElementDestroyedNotification as String
private let axMiniaturizedNotification = kAXWindowMiniaturizedNotification as String
private let axDeminiaturizedNotification = kAXWindowDeminiaturizedNotification as String
private let axMovedNotificationName = kAXMovedNotification as String
private let axResizedNotificationName = kAXResizedNotification as String
private let axWindowCreatedNotificationName = kAXWindowCreatedNotification as String
private let axMainWindowChangedNotificationName = kAXMainWindowChangedNotification as String

struct PlaceholderResizeAxes: OptionSet {
    let rawValue: Int

    static let horizontal = PlaceholderResizeAxes(rawValue: 1 << 0)
    static let vertical = PlaceholderResizeAxes(rawValue: 1 << 1)
}

private struct PlaceholderTarget {
    let screenId: CGDirectDisplayID
    let zoneIndex: Int
}

private final class PlaceholderContentView: NSView {
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

private struct AccessibilityElementKey: Hashable {
    let element: AXUIElement

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    static func == (lhs: AccessibilityElementKey, rhs: AccessibilityElementKey) -> Bool {
        return CFEqual(lhs.element, rhs.element)
    }
}

/// Encapsulates AppKit window creation and manipulation
class WindowController {
    private let windowRegistry = ManagedWindowRegistry()
    private let accessibilityWatcher: AccessibilityWatcher
    private var windowDelegates: [Int: ManagedWindowDelegate] = [:]
    private var externalWindows: [ExternalWindowIdentifier: ManagedWindow] = [:]
    private var externalWindowsByElement: [AccessibilityElementKey: ManagedWindow] = [:]
    private var programmaticUpdateWindowIds: Set<Int> = []
    private var ignoredBundleIdentifiers: Set<String>
    private var accessibilityPermissionWarningShown = false
    weak var delegate: WindowControllerDelegate?
    private var currentDraggingWindowId: Int?
    private var mouseUpMonitor: Any?
    private var mouseUpGlobalMonitor: Any?
    private var resizingWindowId: Int?
    private let primaryScreenBounds: CGRect

    struct CaptureResult {
        let windows: [ManagedWindow]
        let needsRetry: Bool
    }

    init(ignoredBundleIdentifiers: Set<String> = [], primaryScreenBounds: CGRect) {
        self.accessibilityWatcher = AccessibilityWatcher(
            windowNotifications: AccessibilityNotificationCatalog.windowNotifications,
            applicationNotifications: AccessibilityNotificationCatalog.applicationNotifications
        )
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        self.primaryScreenBounds = primaryScreenBounds
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.handleMouseUp()
            return event
        }
        mouseUpGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.handleMouseUp()
        }
        accessibilityWatcher.delegate = self
    }

    deinit {
        accessibilityWatcher.cancelAllObservers()
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseUpGlobalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

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

    @objc private func handlePlaceholderClose(_ sender: NSButton) {
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

    /// Attempt to capture the frontmost standard window of the active application.
    /// Returns the managed wrapper if successful.
    func captureFrontmostWindow() -> ManagedWindow? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            Logger.debug("No frontmost application available to capture")
            return nil
        }
        return captureFocusedWindow(application: frontmostApp, allowCreating: true)
    }

    /// Attempt to capture the focused window for the specified process identifier.
    /// Returns the managed wrapper if successful.
    func captureFocusedWindow(pid: pid_t, allowCreating: Bool = true) -> ManagedWindow? {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            Logger.debug("No running application for pid \(pid); cannot capture focused window")
            return nil
        }
        return captureFocusedWindow(application: application, allowCreating: allowCreating)
    }

    /// Attempt to return the focused window for the specified pid if it is already tracked.
    /// Does not create new ManagedWindow instances.
    func focusedWindowIfTracked(pid: pid_t) -> ManagedWindow? {
        let managed = captureFocusedWindow(pid: pid, allowCreating: false)
        if let managed {
            Logger.debug(
                "focusedWindowIfTracked: pid \(pid) -> window \(managed.windowId) (zone: \(managed.zoneIndex.map(String.init) ?? "none"), screen: \(managed.screenDisplayId.map(String.init) ?? "unknown"))"
            )
        } else {
            Logger.debug("focusedWindowIfTracked: pid \(pid) has no tracked focused window")
        }
        return managed
    }

    private func captureFocusedWindow(application: NSRunningApplication, allowCreating: Bool) -> ManagedWindow? {
        guard ensureAccessibilityPermissions() else {
            Logger.debug("Accessibility permissions missing; cannot capture focused window for pid \(application.processIdentifier)")
            return nil
        }

        if let bundleId = application.bundleIdentifier,
           ignoredBundleIdentifiers.contains(bundleId) {
            Logger.debug("Skipping capture for ignored bundle \(bundleId)")
            return nil
        }

        let pid = application.processIdentifier
        if pid == getpid() {
            Logger.debug("Requested capture for LatticeTopology; nothing to capture")
            return nil
        }

        let appElement = accessibilityWatcher.applicationElement(for: pid)

        var windowObject: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowObject)
        guard windowResult == .success, let windowObject else {
            Logger.debug("Failed to obtain focused window for pid \(pid) (AX error \(windowResult.rawValue))")
            return nil
        }

        guard CFGetTypeID(windowObject) == AXUIElementGetTypeID() else {
            Logger.debug("Focused element for pid \(pid) is not a window element")
            return nil
        }

        let windowElement = unsafeBitCast(windowObject, to: AXUIElement.self)

        if let existing = existingManagedWindow(for: windowElement) {
            Logger.debug("captureFocusedWindow: returning existing managed window \(existing.windowId) for pid \(pid)")
            return existing
        }

        guard allowCreating else {
            Logger.debug("captureFocusedWindow: focused window for pid \(pid) is not yet tracked and allowCreating=false")
            return nil
        }

        return captureWindowIfNeeded(
            element: windowElement,
            pid: pid,
            appElement: appElement,
            allowReturningExisting: true,
            notifyDelegate: true
        )
    }

    private func existingManagedWindow(for element: AXUIElement) -> ManagedWindow? {
        let elementKey = AccessibilityElementKey(element: element)
        if let existing = externalWindowsByElement[elementKey] {
            return existing
        }

        if let identifier = externalIdentifier(for: element),
           let existing = externalWindows[identifier] {
            externalWindowsByElement[elementKey] = existing
            return existing
        }

        return nil
    }

    /// Capture all top-level windows for the specified application.
    /// - Parameters:
    ///   - application: The running application whose windows should be managed.
    ///   - notifyDelegate: When true, the delegate is notified for each newly captured window.
    ///   - allowExisting: When true, existing managed windows are included in the result.
    /// - Returns: Newly captured windows (and existing ones if requested) along with retry guidance.
    func captureWindows(
        for application: NSRunningApplication,
        notifyDelegate: Bool,
        allowExisting: Bool = false
    ) -> CaptureResult {
        guard ensureAccessibilityPermissions() else {
            return CaptureResult(windows: [], needsRetry: false)
        }

        guard application.processIdentifier != getpid() else {
            return CaptureResult(windows: [], needsRetry: false)
        }

        let bundleIdentifier = application.bundleIdentifier
        if let bundleId = bundleIdentifier,
           ignoredBundleIdentifiers.contains(bundleId) {
            return CaptureResult(windows: [], needsRetry: false)
        }

        let pid = application.processIdentifier
        let appElement = accessibilityWatcher.applicationElement(for: pid)

        var needsRetry = false
        if let observerResult = accessibilityWatcher.ensureObserver(for: pid, appElement: appElement, bundleIdentifier: bundleIdentifier) {
            needsRetry = observerResult.needsRetry
        } else {
            return CaptureResult(windows: [], needsRetry: true)
        }

        var windowsObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
        if status != .success {
            let bundleDescription = bundleIdentifier ?? "unknown-bundle-identifier"
            Logger.debug("Failed to enumerate windows for pid \(pid) (bundle \(bundleDescription)) (AX error \(status.rawValue))")
            if status == .cannotComplete {
                needsRetry = true
            }
            return CaptureResult(windows: [], needsRetry: needsRetry)
        }
        guard let windowsObject else {
            let bundleDescription = bundleIdentifier ?? "unknown-bundle-identifier"
            Logger.debug("AX windows attribute returned nil for pid \(pid) (bundle \(bundleDescription))")
            return CaptureResult(windows: [], needsRetry: needsRetry)
        }

        var captured: [ManagedWindow] = []

        if let windowElements = windowsObject as? [AXUIElement] {
            for element in windowElements {
                if let managed = captureWindowIfNeeded(
                    element: element,
                    pid: pid,
                    appElement: appElement,
                    allowReturningExisting: allowExisting,
                    notifyDelegate: notifyDelegate
                ) {
                    captured.append(managed)
                }
            }
        } else if CFGetTypeID(windowsObject) == CFArrayGetTypeID() {
            let array = unsafeBitCast(windowsObject, to: CFArray.self)
            let count = CFArrayGetCount(array)
            for index in 0..<count {
                let rawElement = CFArrayGetValueAtIndex(array, index)
                let element = unsafeBitCast(rawElement, to: AXUIElement.self)
                if let managed = captureWindowIfNeeded(
                    element: element,
                    pid: pid,
                    appElement: appElement,
                    allowReturningExisting: allowExisting,
                    notifyDelegate: notifyDelegate
                ) {
                    captured.append(managed)
                }
            }
        }

        return CaptureResult(windows: captured, needsRetry: needsRetry)
    }

    private func captureWindowIfNeeded(
        element: AXUIElement,
        pid: pid_t,
        appElement: AXUIElement,
        allowReturningExisting: Bool,
        notifyDelegate: Bool
    ) -> ManagedWindow? {
        // Try to get window number for debugging
        var windowNumber: CGWindowID = 0
        var windowNumStr = "unknown"
        if _AXUIElementGetWindow(element, &windowNumber) == .success {
            windowNumStr = String(windowNumber)
        }

        Logger.debug("captureWindowIfNeeded: Attempting to capture window (CGWindowID: \(windowNumStr)) for pid \(pid)")

        guard isStandardWindow(element) else {
            Logger.debug("captureWindowIfNeeded: Window (CGWindowID: \(windowNumStr)) is not a standard window for pid \(pid)")
            return nil
        }

        if isWindowMinimized(element) {
            Logger.debug("captureWindowIfNeeded: Window is minimized for pid \(pid)")
            return nil
        }

        if let existing = existingManagedWindow(for: element) {
            Logger.debug("captureWindowIfNeeded: Window already exists for pid \(pid), allowReturningExisting=\(allowReturningExisting)")
            return allowReturningExisting ? existing : nil
        }

        let identifier = externalIdentifier(for: element)
        let elementKey = AccessibilityElementKey(element: element)
        let windowId = windowRegistry.allocateIdentifier()
        let managed = ManagedWindow(
            windowId: windowId,
            backing: .accessibility(element: element, pid: pid, windowNumber: identifier?.windowNumber),
            isPlaceholder: false
        )
        windowRegistry.insert(managed)
        externalWindowsByElement[elementKey] = managed
        if let identifier {
            externalWindows[identifier] = managed
            Logger.debug("Captured external window \(identifier.windowNumber) from pid \(pid) as managed id \(managed.windowId)")
        } else {
            Logger.debug("Captured external window with unknown window number from pid \(pid) as managed id \(managed.windowId)")
        }

        registerAccessibilityNotifications(for: managed, appElement: appElement)

        if notifyDelegate {
            Logger.debug("captureWindowIfNeeded: Notifying delegate about captured window \(managed.windowId) for pid \(pid)")
            delegate?.windowController(self, didCaptureExternalWindow: managed)
        }

        Logger.debug("captureWindowIfNeeded: Successfully captured window \(managed.windowId) for pid \(pid)")
        return managed
    }

    /// Best-effort minimization of all standard windows belonging to other applications.
    func minimizeAllExternalWindows() {
        guard ensureAccessibilityPermissions() else {
            return
        }

        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && app.processIdentifier != getpid() {
            let pid = app.processIdentifier
            if let bundleId = app.bundleIdentifier,
               ignoredBundleIdentifiers.contains(bundleId) {
                Logger.debug("Skipping minimization for ignored bundle \(bundleId)")
                continue
            }
            let appElement = accessibilityWatcher.applicationElement(for: pid)

            var windowsObject: AnyObject?
            let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
            guard status == .success, let windowElements = windowsObject as? [AXUIElement] else {
                continue
            }

            for windowElement in windowElements {
                _ = AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    /// Get a managed window by ID
    func window(withId windowId: Int) -> ManagedWindow? {
        return windowRegistry.window(withId: windowId)
    }

    /// Show a window at the specified frame (frame is in screen-local coordinates)
    func showWindow(_ managedWindow: ManagedWindow, at frame: CGRect, on screen: ScreenDescriptor) {
        let accessibilityFrame = screen.screenToAccessibility(frame)
        switch managedWindow.backing {
        case .appKit(let window):
            // Convert accessibility coordinates back to Cocoa for AppKit windows
            let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: accessibilityFrame,
                primaryScreenBounds: primaryScreenBounds
            )
            window.setFrame(cocoaFrame, display: true)
            if managedWindow.isPlaceholder {
                Logger.debug("Bringing placeholder window \(managedWindow.windowId) to front via orderFront")
            }
            window.orderFront(nil)
        case .accessibility(let element, _, _):
            // Accessibility API uses screen coordinates directly
            performProgrammaticUpdate(for: managedWindow.windowId) {
                _ = setAccessibilityFrame(element: element, frame: accessibilityFrame)
            }
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Showed window \(managedWindow.windowId) on screen \(screenIndex) at frame \(frame)")
    }

    /// Minimize a window
    func minimizeWindow(_ managedWindow: ManagedWindow) {
        switch managedWindow.backing {
        case .appKit(let window):
            window.miniaturize(nil)
        case .accessibility(let element, _, _):
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
        Logger.debug("Minimized window \(managedWindow.windowId)")
    }

    /// Unminimize a window
    func unminimizeWindow(_ managedWindow: ManagedWindow) {
        switch managedWindow.backing {
        case .appKit(let window):
            window.deminiaturize(nil)
        case .accessibility(let element, _, _):
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        Logger.debug("Unminimized window \(managedWindow.windowId)")
    }

    /// Close a window
    func closeWindow(_ managedWindow: ManagedWindow) {
        switch managedWindow.backing {
        case .appKit(let window):
            window.close()
        case .accessibility(let element, _, _):
            removeAccessibilityTracking(for: managedWindow)
            _ = AXUIElementPerformAction(element, axCloseAction)
        }
        windowRegistry.removeWindow(withId: managedWindow.windowId)
        windowDelegates.removeValue(forKey: managedWindow.windowId)
        if let identifier = managedWindow.externalIdentifier {
            externalWindows.removeValue(forKey: identifier)
        }
        Logger.debug("Closed window \(managedWindow.windowId)")
    }

    /// Resize and reposition a window to match a frame (frame is in screen-local coordinates)
    func moveWindow(_ managedWindow: ManagedWindow, to frame: CGRect, on screen: ScreenDescriptor) {
        let accessibilityFrame = screen.screenToAccessibility(frame)
        switch managedWindow.backing {
        case .appKit(let window):
            let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: accessibilityFrame,
                primaryScreenBounds: primaryScreenBounds
            )
            window.setFrame(cocoaFrame, display: true, animate: false)
        case .accessibility(let element, _, _):
            // Accessibility API uses screen coordinates directly
            performProgrammaticUpdate(for: managedWindow.windowId) {
                _ = setAccessibilityFrame(element: element, frame: accessibilityFrame)
            }
        }
        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Moved window \(managedWindow.windowId) on screen \(screenIndex) to frame \(frame)")
    }

    private func performProgrammaticUpdate(for windowId: Int, _ block: () -> Void) {
        programmaticUpdateWindowIds.insert(windowId)
        block()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.programmaticUpdateWindowIds.remove(windowId)
        }
    }

    private func setAccessibilityFrame(element: AXUIElement, frame: CGRect) -> Bool {
        let positionResult = setAccessibilityPoint(element: element, attribute: kAXPositionAttribute as CFString, point: frame.origin)
        let sizeResult = setAccessibilitySize(element: element, size: frame.size)
        return positionResult && sizeResult
    }

    private func setAccessibilityPoint(element: AXUIElement, attribute: CFString, point: CGPoint) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &mutablePoint) else {
            return false
        }
        let status = AXUIElementSetAttributeValue(element, attribute, value)
        return status == .success
    }

    private func setAccessibilitySize(element: AXUIElement, size: CGSize) -> Bool {
        var mutableSize = size
        guard let value = AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &mutableSize) else {
            return false
        }
        let status = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        return status == .success
    }

    private func isWindowMinimized(_ element: AXUIElement) -> Bool {
        var minimizedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimizedValue)
        guard status == .success, let minimizedValue else {
            return false
        }
        if CFGetTypeID(minimizedValue) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(minimizedValue, to: CFBoolean.self))
        }
        if let number = minimizedValue as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private func ensureAccessibilityPermissions() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        if !accessibilityPermissionWarningShown {
            accessibilityPermissionWarningShown = true
            print("LatticeTopology requires Accessibility access. Enable it in System Settings ▸ Privacy & Security ▸ Accessibility.")
        }
        return false
    }

    private func isStandardWindow(_ element: AXUIElement) -> Bool {
        var roleObject: AnyObject?
        let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleObject)
        guard roleStatus == .success, let role = roleObject as? String, role == kAXWindowRole as String else {
            if roleStatus != .success {
                Logger.debug("isStandardWindow: Failed to get role attribute, AX error \(roleStatus.rawValue)")
            }
            return false
        }

        var subroleObject: AnyObject?
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleObject)
        if subroleStatus == .success, let subrole = subroleObject as? String {
            guard subrole == kAXStandardWindowSubrole as String else {
                Logger.debug("isStandardWindow: Window has non-standard subrole: \(subrole)")
                return false
            }
        } else if subroleStatus != .success {
            Logger.debug("isStandardWindow: Failed to get subrole attribute, AX error \(subroleStatus.rawValue)")
        }

        // Check isMovable attribute (per SPECIFICATION.md)
        // Use the same approach as winmanmon: check if position is settable
        var isPositionSettable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &isPositionSettable)
        if settableStatus != .success || !isPositionSettable.boolValue {
            if settableStatus != .success {
                Logger.debug("isStandardWindow: Failed to check if position is settable, AX error \(settableStatus.rawValue)")
            } else {
                Logger.debug("isStandardWindow: Window position is not settable (not movable)")
            }
            return false
        }

        // Check for zoom button (hasZoom) attribute (per SPECIFICATION.md)
        var zoomButtonValue: CFTypeRef?
        let zoomStatus = AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &zoomButtonValue)

        var hasZoomButton = false
        if zoomStatus == .success {
            if let zoomButtonValue {
                let typeId = CFGetTypeID(zoomButtonValue)
                if typeId == CFNullGetTypeID() {
                    Logger.debug("isStandardWindow: Zoom button attribute returned CFNull (no zoom button)")
                } else if typeId == AXValueGetTypeID() {
                    let axValue = zoomButtonValue as! AXValue
                    let valueType = AXValueGetType(axValue)
                    let axErrorTypeRawValue: UInt32 = 5  // kAXValueAXErrorType
                    if valueType.rawValue == axErrorTypeRawValue {
                        var underlyingError = AXError.success
                        if AXValueGetValue(axValue, valueType, &underlyingError) {
                            Logger.debug("isStandardWindow: Zoom button attribute returned AX error \(underlyingError.rawValue)")
                        } else {
                            Logger.debug("isStandardWindow: Zoom button attribute returned AX error type value without readable code")
                        }
                    } else {
                        hasZoomButton = true
                    }
                } else {
                    hasZoomButton = true
                }
            } else {
                Logger.debug("isStandardWindow: Zoom button attribute returned nil (no zoom button)")
            }
        } else if zoomStatus == .noValue {
            Logger.debug("isStandardWindow: Zoom button attribute reports no value (no zoom button)")
        } else {
            Logger.debug("isStandardWindow: Failed to get zoom button attribute, AX error \(zoomStatus.rawValue)")
        }

        if !hasZoomButton {
            Logger.debug("isStandardWindow: Window has no zoom button")
            return false
        }

        // Check window height (must be >= 250px tall)
        if let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) {
            if size.height < 250 {
                Logger.debug("isStandardWindow: Window height \(size.height) is less than 250px minimum")
                return false
            }
        } else {
            // If we can't get the size, we treat it as not meeting the criteria
            Logger.debug("isStandardWindow: Unable to get window size for height check")
            return false
        }

        return true
    }

    private func externalIdentifier(for element: AXUIElement) -> ExternalWindowIdentifier? {
        var pid: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &pid)
        guard pidStatus == .success else {
            return nil
        }

        var numberObject: CFTypeRef?
        let numberStatus = AXUIElementCopyAttributeValue(element, axWindowNumberAttribute, &numberObject)
        guard numberStatus == .success, let numberObject else {
            return nil
        }

        if let number = numberObject as? NSNumber {
            return ExternalWindowIdentifier(pid: pid, windowNumber: number.intValue)
        }

        return nil
    }

    private func registerAccessibilityNotifications(for managed: ManagedWindow, appElement: AXUIElement) {
        guard case .accessibility(let element, let pid, _) = managed.backing else {
            return
        }

        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard accessibilityWatcher.ensureObserver(for: pid, appElement: appElement, bundleIdentifier: bundleId) != nil else {
            return
        }

        accessibilityWatcher.registerWindowNotifications(for: element, pid: pid)
    }

    private func managedWindow(matching element: AXUIElement) -> ManagedWindow? {
        for window in windowRegistry.allWindows {
            if let candidate = window.accessibilityElement, CFEqual(candidate, element) {
                return window
            }
        }
        if let identifier = externalIdentifier(for: element) {
            return externalWindows[identifier]
        }
        return nil
    }

    func handleAXNotification(element: AXUIElement, notification: CFString) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAXNotificationOnMain(element: element, notification: notification)
        }
    }

    private func handleAXNotificationOnMain(element: AXUIElement, notification: CFString) {
        let notificationName = notification as String

        Logger.debug("AX notification received: \(notificationName)")

        if notificationName == axWindowCreatedNotificationName {
            var pid: pid_t = 0
            let status = AXUIElementGetPid(element, &pid)
            guard status == .success, pid != getpid() else {
                return
            }

            if let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               ignoredBundleIdentifiers.contains(bundleId) {
                return
            }

            // Get window title for debugging
            var titleValue: AnyObject?
            var windowTitle = "unknown"
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String {
                windowTitle = title.isEmpty ? "(empty title)" : title
            }

            Logger.debug("AXWindowCreated notification received for pid \(pid), window title: \(windowTitle)")

            let appElement = accessibilityWatcher.applicationElement(for: pid)

            let capturedWindow = captureWindowIfNeeded(
                element: element,
                pid: pid,
                appElement: appElement,
                allowReturningExisting: false,
                notifyDelegate: true
            )

            if capturedWindow == nil {
                Logger.debug("AXWindowCreated: Failed to capture window '\(windowTitle)' for pid \(pid), requesting capture retry")
                // If the window couldn't be captured (likely due to .cannotComplete errors),
                // notify delegate to schedule a retry
                delegate?.windowCreationFailedRetryNeeded(forPid: pid)
            }
            return
        }

        if notificationName == axMainWindowChangedNotificationName {
            var pid: pid_t = 0
            let status = AXUIElementGetPid(element, &pid)

            var resolvedPid: pid_t?
            if status == .success {
                resolvedPid = pid
            } else if let managed = managedWindow(matching: element),
                      case .accessibility(_, let managedPid, _) = managed.backing {
                resolvedPid = managedPid
            }

            guard let targetPid = resolvedPid, targetPid != getpid() else {
                return
            }

            Logger.debug("AX main window changed for pid \(targetPid)")

            let appElement = accessibilityWatcher.applicationElement(for: targetPid)

            if status == .success {
                _ = captureWindowIfNeeded(
                    element: element,
                    pid: targetPid,
                    appElement: appElement,
                    allowReturningExisting: true,
                    notifyDelegate: true
                )
            }

            delegate?.windowFocusChanged(pid: targetPid)
            return
        }

        if notificationName == "AXFocusedWindowChanged" {
            // When focus changes, validate windows for the application
            // This catches window closures that didn't fire destroy notifications
            var pid: pid_t = 0
            let status = AXUIElementGetPid(element, &pid)
            if status == .success, pid != getpid() {
                Logger.debug("Focus changed in app pid \(pid), validating windows")
                delegate?.windowFocusChanged(pid: pid)
            }
            return
        }

        guard let managed = managedWindow(matching: element) else {
            return
        }

        switch notificationName {
        case axDestroyedNotification:
            Logger.debug("*** AXUIElementDestroyed notification received for window \(managed.windowId)")
            delegate?.windowWillClose(windowId: managed.windowId)
            removeAccessibilityTracking(for: managed)
            if let identifier = managed.externalIdentifier {
                externalWindows.removeValue(forKey: identifier)
            }
            windowRegistry.removeWindow(withId: managed.windowId)

        case axMiniaturizedNotification:
            Logger.debug("External window \(managed.windowId) minimized")
            delegate?.windowDidMiniaturize(windowId: managed.windowId)

        case axDeminiaturizedNotification:
            Logger.debug("External window \(managed.windowId) deminiaturized")
            delegate?.windowDidDeminiaturize(windowId: managed.windowId)

        case axMovedNotificationName:
            guard !programmaticUpdateWindowIds.contains(managed.windowId) else {
                return
            }
            Logger.debug("External window \(managed.windowId) moved by user")
            let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
            if currentDraggingWindowId != managed.windowId {
                currentDraggingWindowId = managed.windowId
                delegate?.windowManualMoveDidBegin(windowId: managed.windowId, frame: accessibilityFrame)
            }
            delegate?.windowManualMoveDidUpdate(windowId: managed.windowId, frame: accessibilityFrame)

        case axResizedNotificationName:
            guard !programmaticUpdateWindowIds.contains(managed.windowId) else {
                return
            }
            Logger.debug("External window \(managed.windowId) resized by user")
            if let screenFrame = actualFrameInScreenCoordinates(for: managed) {
                delegate?.windowManualResizeDidEnd(windowId: managed.windowId, screenId: managed.screenDisplayId, frame: screenFrame)
            } else {
                delegate?.windowManualResizeDidEnd(windowId: managed.windowId, screenId: managed.screenDisplayId, frame: .zero)
            }

        default:
            break
        }
    }

    private func removeAccessibilityTracking(for managed: ManagedWindow) {
        guard case .accessibility(let element, let pid, _) = managed.backing else {
            return
        }

        externalWindowsByElement.removeValue(forKey: AccessibilityElementKey(element: element))
        accessibilityWatcher.removeWindowNotifications(for: element, pid: pid)

        let stillManaged = windowRegistry.contains { window in
            guard case .accessibility(_, let otherPid, _) = window.backing else {
                return false
            }
            return otherPid == pid && window.windowId != managed.windowId
        }

        if !stillManaged {
            accessibilityWatcher.removeObserver(for: pid)
        }
    }

    /// Detect and prune external windows whose accessibility elements have been destroyed.
    /// Uses the window server as the ground truth source.
    /// - Returns: The window identifiers that were removed.
    func pruneDestroyedExternalWindows() -> [Int] {
        // Get all actual windows from the window server (ground truth)
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var actualWindows = Set<ExternalWindowIdentifier>()
        for windowInfo in windowList {
            if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
               let windowNumber = windowInfo[kCGWindowNumber as String] as? Int {
                actualWindows.insert(ExternalWindowIdentifier(pid: ownerPID, windowNumber: windowNumber))
            }
        }

        var stale: [(Int, ManagedWindow, String)] = []

        for managed in windowRegistry.allWindows {
            let windowId = managed.windowId
            guard case .accessibility(_, let pid, let windowNumber) = managed.backing else {
                continue
            }

            if let windowNumber {
                let identifier = ExternalWindowIdentifier(pid: pid, windowNumber: windowNumber)
                if !actualWindows.contains(identifier) {
                    stale.append((windowId, managed, "missing-from-cgwindowlist"))
                    continue
                }
            }

            if !isAccessibilityElementAlive(managed) {
                stale.append((windowId, managed, "ax-element-invalid"))
            }
        }

        if stale.isEmpty {
            return []
        }

        var removedWindowIds: [Int] = []
        for (windowId, managed, reason) in stale {
            Logger.debug("Detected destroyed external window \(windowId) (reason: \(reason)); pruning")
            removeAccessibilityTracking(for: managed)
            windowRegistry.removeWindow(withId: windowId)
            if let identifier = managed.externalIdentifier {
                externalWindows.removeValue(forKey: identifier)
            }
            removedWindowIds.append(windowId)
            Logger.debug("Pruned destroyed external window \(windowId)")
        }

        return removedWindowIds
    }

    /// Detect and prune external windows for a specific PID whose accessibility elements have been destroyed.
    /// - Parameter pid: The process identifier to check windows for.
    /// - Returns: The window identifiers that were removed.
    func pruneDestroyedWindowsForPid(_ pid: pid_t) -> [Int] {
        // Get the ground truth from the window server
        let actualWindowNumbers = getActualWindowNumbersFromWindowServer(forPid: pid)

        var stale: [(Int, ManagedWindow, String)] = []

        for managed in windowRegistry.allWindows {
            let windowId = managed.windowId
            guard case .accessibility(_, let windowPid, let windowNumber) = managed.backing else {
                continue
            }

            // Only check windows for this specific PID
            guard windowPid == pid else {
                continue
            }

            if let windowNumber {
                // If the window number is not in the actual windows from window server, it's been destroyed
                if !actualWindowNumbers.contains(windowNumber) {
                    stale.append((windowId, managed, "missing-from-cgwindowlist"))
                    continue
                }
            }

            if !isAccessibilityElementAlive(managed) {
                stale.append((windowId, managed, "ax-element-invalid"))
            }
        }

        if stale.isEmpty {
            return []
        }

        var removedWindowIds: [Int] = []
        for (windowId, managed, reason) in stale {
            Logger.debug("Detected destroyed external window \(windowId) for pid \(pid) (reason: \(reason)); pruning")
            removeAccessibilityTracking(for: managed)
            windowRegistry.removeWindow(withId: windowId)
            if let identifier = managed.externalIdentifier {
                externalWindows.removeValue(forKey: identifier)
            }
            removedWindowIds.append(windowId)
            Logger.debug("Pruned destroyed external window \(windowId)")
        }

        return removedWindowIds
    }

    /// Remove all accessibility-backed managed windows for a terminated process.
    /// - Parameter pid: The process identifier whose windows should be discarded.
    /// - Returns: The window identifiers that were removed.
    func removeAllWindows(forPid pid: pid_t) -> [Int] {
        let windowsForPid = windowRegistry.allWindows.filter { window in
            guard case .accessibility(_, let windowPid, _) = window.backing else {
                return false
            }
            return windowPid == pid
        }

        guard !windowsForPid.isEmpty else {
            return []
        }

        let windowIds = windowsForPid.map { $0.windowId }

        for managed in windowsForPid {
            let windowId = managed.windowId
            Logger.debug("Removing external window \(windowId) for terminated pid \(pid)")
            removeAccessibilityTracking(for: managed)
            if let identifier = managed.externalIdentifier {
                externalWindows.removeValue(forKey: identifier)
            }
            windowRegistry.removeWindow(withId: windowId)
            programmaticUpdateWindowIds.remove(windowId)
            if currentDraggingWindowId == windowId {
                currentDraggingWindowId = nil
            }
            if resizingWindowId == windowId {
                resizingWindowId = nil
            }
        }

        return windowIds
    }

    /// Query the window server for actual window numbers for a given PID.
    /// This is the ground truth source for which windows exist.
    private func getActualWindowNumbersFromWindowServer(forPid pid: pid_t) -> Set<Int> {
        var windowNumbers = Set<Int>()

        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return windowNumbers
        }

        for windowInfo in windowList {
            if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
               ownerPID == pid,
               let windowNumber = windowInfo[kCGWindowNumber as String] as? Int {
                windowNumbers.insert(windowNumber)
            }
        }

        return windowNumbers
    }

    private func isAccessibilityElementAlive(_ managed: ManagedWindow) -> Bool {
        guard case .accessibility(let element, _, _) = managed.backing else {
            return true
        }

        func statusIndicatesInvalid(_ status: AXError) -> Bool {
            switch status {
            case .invalidUIElement, .cannotComplete, .illegalArgument:
                return true
            default:
                return false
            }
        }

        func attributeAppearsValid(_ attribute: CFString) -> Bool {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute, &value)
            if status == .success || status == .noValue || status == .attributeUnsupported {
                return true
            }
            if statusIndicatesInvalid(status) {
                Logger.debug("Accessibility attribute \(attribute as String) for window \(managed.windowId) returned AX error \(status.rawValue)")
                return false
            }
            Logger.debug("Accessibility attribute \(attribute as String) for window \(managed.windowId) returned AX status \(status.rawValue); treating as still alive")
            return true
        }

        let roleAlive = attributeAppearsValid(kAXRoleAttribute as CFString)
        if !roleAlive {
            return false
        }

        return attributeAppearsValid(kAXPositionAttribute as CFString)
    }

    func constrainedPlaceholderSize(for windowId: Int, proposedSize: NSSize, currentSize: NSSize) -> NSSize {
        guard let managed = windowRegistry.window(withId: windowId),
              managed.isPlaceholder,
              let zoneIndex = managed.zoneIndex,
              let screenId = managed.screenDisplayId else {
            return proposedSize
        }

        let allowedAxes = delegate?.placeholderAllowedResizeAxes(screenId: screenId, zoneIndex: zoneIndex) ?? []
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

        guard let managed = windowRegistry.window(withId: windowId), !managed.isPlaceholder else {
            return
        }

        Logger.debug("Finished dragging window \(windowId)")
        let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
        delegate?.windowManualMoveDidEnd(windowId: windowId, finalFrame: accessibilityFrame)
    }

    /// Get the actual frame of a window in screen-local coordinates
    func actualFrameInScreenCoordinates(for managedWindow: ManagedWindow, on screen: ScreenDescriptor) -> CGRect {
        switch managedWindow.backing {
        case .appKit(let window):
            let cocoaFrame = window.frame
            return screen.cocoaToScreen(cocoaFrame)
        case .accessibility(let element, _, _):
            guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
                  let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
                return .zero
            }
            let accessibilityFrame = CGRect(origin: position, size: size)
            return screen.accessibilityToScreen(accessibilityFrame)
        }
    }

    /// Convenience helper that resolves the screen descriptor via the delegate.
    func actualFrameInScreenCoordinates(for managedWindow: ManagedWindow) -> CGRect? {
        guard let screenId = managedWindow.screenDisplayId,
              let descriptor = delegate?.screenDescriptor(for: screenId) else {
            return nil
        }
        return actualFrameInScreenCoordinates(for: managedWindow, on: descriptor)
    }

    /// Get the actual frame expressed in accessibility coordinates (origin at primary display top-left).
    func actualFrameInAccessibilityCoordinates(for managedWindow: ManagedWindow) -> CGRect? {
        switch managedWindow.backing {
        case .appKit(let window):
            let cocoaFrame = window.frame
            return CoordinateConversion.cocoaToAccessibility(
                cocoaFrame: cocoaFrame,
                primaryScreenBounds: primaryScreenBounds
            )
        case .accessibility(let element, _, _):
            guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
                  let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
                return nil
            }
            return CGRect(origin: position, size: size)
        }
    }

    /// Get all managed windows
    var allWindows: [ManagedWindow] {
        return windowRegistry.allWindows
    }
}

// Helper methods for ManagedWindow to access coordinate conversion
extension ManagedWindow {
    /// Helper methods to copy AX values - made internal for use by WindowController
    static func copyCGPointValue(element: AXUIElement, attribute: CFString) -> CGPoint? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard status == .success, let rawValue else {
            return nil
        }
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)

        var point = CGPoint.zero
        guard AXValueGetType(axValue) == AXValueType(rawValue: kAXValueCGPointType),
              AXValueGetValue(axValue, AXValueType(rawValue: kAXValueCGPointType)!, &point) else {
            return nil
        }
        return point
    }

    static func copyCGSizeValue(element: AXUIElement, attribute: CFString) -> CGSize? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard status == .success, let rawValue else {
            return nil
        }
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)

        var size = CGSize.zero
        guard AXValueGetType(axValue) == AXValueType(rawValue: kAXValueCGSizeType),
              AXValueGetValue(axValue, AXValueType(rawValue: kAXValueCGSizeType)!, &size) else {
            return nil
        }
        return size
    }
}

/// Delegate protocol for window controller events
protocol WindowControllerDelegate: AnyObject {
    func placeholderCloseRequested(screenId: CGDirectDisplayID, zoneIndex: Int)
    func placeholderActivated(screenId: CGDirectDisplayID, zoneIndex: Int)
    func windowWillClose(windowId: Int)
    func windowDidMiniaturize(windowId: Int)
    func windowDidDeminiaturize(windowId: Int)
    func windowFocusChanged(pid: pid_t)
    func placeholderLiveResizeDidBegin(screenId: CGDirectDisplayID, zoneIndex: Int)
    func placeholderLiveResized(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect)
    func placeholderLiveResizeDidEnd(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect)
    func placeholderAllowedResizeAxes(screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderResizeAxes
    func windowManualResizeDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect)
    func windowManualMoveDidBegin(windowId: Int, frame: CGRect)
    func windowManualMoveDidUpdate(windowId: Int, frame: CGRect)
    func windowManualMoveDidEnd(windowId: Int, finalFrame: CGRect)
    func screenDescriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?
    func windowController(_ controller: WindowController, didCaptureExternalWindow window: ManagedWindow)
    func windowCreationFailedRetryNeeded(forPid pid: pid_t)
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
        guard let managed = windowRegistry.window(withId: windowId) else {
            return
        }

        if managed.isPlaceholder {
            guard let zoneIndex = managed.zoneIndex,
                  let screenId = managed.screenDisplayId else {
                return
            }
            delegate?.placeholderLiveResizeDidBegin(screenId: screenId, zoneIndex: zoneIndex)
        } else {
            resizingWindowId = windowId
        }
    }

    func windowDidResize(windowId: Int) {
        guard let managed = windowRegistry.window(withId: windowId) else {
            return
        }

        if managed.isPlaceholder {
            guard let zoneIndex = managed.zoneIndex,
                  let screenId = managed.screenDisplayId,
                  let screenFrame = actualFrameInScreenCoordinates(for: managed) else {
                return
            }
            delegate?.placeholderLiveResized(screenId: screenId, zoneIndex: zoneIndex, to: screenFrame)
        }
    }

    func windowDidEndLiveResize(windowId: Int) {
        guard let managed = windowRegistry.window(withId: windowId) else {
            return
        }

        if managed.isPlaceholder {
            guard let zoneIndex = managed.zoneIndex,
                  let screenId = managed.screenDisplayId,
                  let screenFrame = actualFrameInScreenCoordinates(for: managed) else {
                return
            }
            delegate?.placeholderLiveResizeDidEnd(screenId: screenId, zoneIndex: zoneIndex, to: screenFrame)
        } else {
            guard resizingWindowId == windowId else {
                return
            }
            resizingWindowId = nil
            Logger.debug("Finished resizing window \(windowId), notifying delegate")
            if let screenFrame = actualFrameInScreenCoordinates(for: managed) {
                delegate?.windowManualResizeDidEnd(windowId: windowId, screenId: managed.screenDisplayId, frame: screenFrame)
            } else {
                delegate?.windowManualResizeDidEnd(windowId: windowId, screenId: managed.screenDisplayId, frame: .zero)
            }
        }
    }

    func windowWillMove(windowId: Int) {
        guard let managed = windowRegistry.window(withId: windowId), !managed.isPlaceholder else {
            return
        }

        currentDraggingWindowId = windowId
        Logger.debug("User began dragging window \(windowId)")
        let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
        delegate?.windowManualMoveDidBegin(windowId: windowId, frame: accessibilityFrame)
    }

    func windowDidMove(windowId: Int) {
        guard currentDraggingWindowId == windowId,
              let managed = windowRegistry.window(withId: windowId),
              let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) else {
            return
        }
        delegate?.windowManualMoveDidUpdate(windowId: windowId, frame: accessibilityFrame)
    }
}
