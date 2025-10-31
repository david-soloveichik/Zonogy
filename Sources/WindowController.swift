import Foundation
import AppKit
import ApplicationServices

private func windowControllerObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let controller = Unmanaged<WindowController>.fromOpaque(refcon).takeUnretainedValue()
    controller.handleAXNotification(element: element, notification: notification)
}

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
    private var nextWindowId = 1
    private var managedWindows: [Int: ManagedWindow] = [:]
    private var windowDelegates: [Int: ManagedWindowDelegate] = [:]
    private var externalWindows: [ExternalWindowIdentifier: ManagedWindow] = [:]
    private var externalWindowsByElement: [AccessibilityElementKey: ManagedWindow] = [:]
    private var accessibilityObservers: [pid_t: AXObserver] = [:]
    private var accessibilityApplications: [pid_t: AXUIElement] = [:]
    private var programmaticUpdateWindowIds: Set<Int> = []
    private var ignoredBundleIdentifiers: Set<String>
    private var accessibilityPermissionWarningShown = false
    private let windowAccessibilityNotifications: [CFString] = [
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
        kAXMovedNotification as CFString,
        kAXResizedNotification as CFString
    ]
    private let applicationAccessibilityNotifications: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString
    ]
    private lazy var observerRefcon: UnsafeMutableRawPointer = {
        Unmanaged.passUnretained(self).toOpaque()
    }()
    weak var delegate: WindowControllerDelegate?
    private var currentDraggingWindowId: Int?
    private var mouseUpMonitor: Any?
    private var mouseUpGlobalMonitor: Any?
    private var resizingWindowId: Int?
    private let primaryScreenBounds: CGRect

    init(ignoredBundleIdentifiers: Set<String> = [], primaryScreenBounds: CGRect) {
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        self.primaryScreenBounds = primaryScreenBounds
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

        let managed = ManagedWindow(
            windowId: windowId,
            backing: .appKit(window),
            isPlaceholder: false
        )
        managedWindows[windowId] = managed

        Logger.debug("Created test window \(windowId)")
        return managed
    }

    /// Create a placeholder window for an empty zone
    func createPlaceholderWindow(frame: CGRect, zoneIndex: Int, on screen: ScreenDescriptor) -> ManagedWindow {
        let windowId = nextWindowId
        nextWindowId += 1

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

        let managed = ManagedWindow(
            windowId: windowId,
            backing: .appKit(window),
            isPlaceholder: true
        )
        managed.screenDisplayId = screen.displayId
        managed.zoneIndex = zoneIndex
        managedWindows[windowId] = managed

        Logger.debug("Created placeholder window \(windowId) for zone \(zoneIndex) on display \(screen.displayId)")
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
    }

    @objc private func handlePlaceholderClose(_ sender: NSButton) {
        let zoneIndex = sender.tag
        let screenId: CGDirectDisplayID?
        if let window = sender.window {
            screenId = managedWindows.values.first(where: { managed in
                managed.isPlaceholder && managed.appKitWindow === window
            })?.screenDisplayId
        } else {
            screenId = nil
        }

        Logger.debug("Placeholder close button clicked for zone \(zoneIndex) on display \(screenId ?? 0)")
        if let screenId {
            delegate?.placeholderCloseRequested(screenId: screenId, zoneIndex: zoneIndex)
        }
    }

    /// Attempt to capture the frontmost standard window of the active application.
    /// Returns the managed wrapper if successful.
    func captureFrontmostWindow() -> ManagedWindow? {
        guard ensureAccessibilityPermissions() else {
            Logger.debug("Accessibility permissions missing; cannot capture frontmost window")
            return nil
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            Logger.debug("No frontmost application available to capture")
            return nil
        }

        if let bundleId = frontmostApp.bundleIdentifier,
           ignoredBundleIdentifiers.contains(bundleId) {
            Logger.debug("Skipping capture for ignored bundle \(bundleId)")
            return nil
        }

        let pid = frontmostApp.processIdentifier
        if pid == getpid() {
            Logger.debug("Frontmost application is LatticeTopology; nothing to capture")
            return nil
        }

        let appElement = accessibilityApplications[pid] ?? AXUIElementCreateApplication(pid)
        accessibilityApplications[pid] = appElement

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
        return captureWindowIfNeeded(
            element: windowElement,
            pid: pid,
            appElement: appElement,
            allowReturningExisting: true,
            notifyDelegate: false
        )
    }

    /// Capture all top-level windows for the specified application.
    /// - Parameters:
    ///   - application: The running application whose windows should be managed.
    ///   - notifyDelegate: When true, the delegate is notified for each newly captured window.
    ///   - allowExisting: When true, existing managed windows are included in the result.
    /// - Returns: Newly captured windows (and existing ones if requested).
    func captureWindows(
        for application: NSRunningApplication,
        notifyDelegate: Bool,
        allowExisting: Bool = false
    ) -> [ManagedWindow] {
        guard ensureAccessibilityPermissions() else {
            return []
        }

        guard application.processIdentifier != getpid() else {
            return []
        }

        if let bundleId = application.bundleIdentifier,
           ignoredBundleIdentifiers.contains(bundleId) {
            return []
        }

        let pid = application.processIdentifier
        let appElement = accessibilityApplications[pid] ?? AXUIElementCreateApplication(pid)
        accessibilityApplications[pid] = appElement

        var windowsObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
        guard status == .success, let windowsObject else {
            if status != .success {
                Logger.debug("Failed to enumerate windows for pid \(pid) (AX error \(status.rawValue))")
            }
            return []
        }

        _ = ensureObserver(for: pid, appElement: appElement)

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

        return captured
    }

    private func captureWindowIfNeeded(
        element: AXUIElement,
        pid: pid_t,
        appElement: AXUIElement,
        allowReturningExisting: Bool,
        notifyDelegate: Bool
    ) -> ManagedWindow? {
        guard isStandardWindow(element) else {
            return nil
        }

        if isWindowMinimized(element) {
            return nil
        }

        let elementKey = AccessibilityElementKey(element: element)
        if let existing = externalWindowsByElement[elementKey] {
            return allowReturningExisting ? existing : nil
        }

        if let identifier = externalIdentifier(for: element),
           let existing = externalWindows[identifier] {
            externalWindowsByElement[elementKey] = existing
            return allowReturningExisting ? existing : nil
        }

        let identifier = externalIdentifier(for: element)
        let managed = ManagedWindow(
            windowId: nextWindowId,
            backing: .accessibility(element: element, pid: pid, windowNumber: identifier?.windowNumber),
            isPlaceholder: false
        )
        nextWindowId += 1

        managedWindows[managed.windowId] = managed
        externalWindowsByElement[elementKey] = managed
        if let identifier {
            externalWindows[identifier] = managed
            Logger.debug("Captured external window \(identifier.windowNumber) from pid \(pid) as managed id \(managed.windowId)")
        } else {
            Logger.debug("Captured external window with unknown window number from pid \(pid) as managed id \(managed.windowId)")
        }

        registerAccessibilityNotifications(for: managed, appElement: appElement)

        if notifyDelegate {
            delegate?.windowController(self, didCaptureExternalWindow: managed)
        }

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
            let appElement = accessibilityApplications[pid] ?? AXUIElementCreateApplication(pid)
            accessibilityApplications[pid] = appElement

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
        return managedWindows[windowId]
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
            window.orderFront(nil)
        case .accessibility(let element, _, _):
            // Accessibility API uses screen coordinates directly
            performProgrammaticUpdate(for: managedWindow.windowId) {
                _ = setAccessibilityFrame(element: element, frame: accessibilityFrame)
            }
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        Logger.debug("Showed window \(managedWindow.windowId) on display \(screen.displayId) at frame \(frame)")
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
        managedWindows.removeValue(forKey: managedWindow.windowId)
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
        Logger.debug("Moved window \(managedWindow.windowId) on display \(screen.displayId) to frame \(frame)")
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
            return false
        }

        var subroleObject: AnyObject?
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleObject)
        if subroleStatus == .success, let subrole = subroleObject as? String {
            guard subrole == kAXStandardWindowSubrole as String else {
                return false
            }
        }

        // Check isMovable attribute (per SPECIFICATION.md)
        var movableObject: AnyObject?
        let movableStatus = AXUIElementCopyAttributeValue(element, "AXMovable" as CFString, &movableObject)
        if movableStatus == .success {
            if let movable = movableObject as? NSNumber, !movable.boolValue {
                return false
            } else if CFGetTypeID(movableObject!) == CFBooleanGetTypeID(),
                      !CFBooleanGetValue(unsafeBitCast(movableObject, to: CFBoolean.self)) {
                return false
            }
        }

        // Check for zoom button (hasZoom) attribute (per SPECIFICATION.md)
        var actionNamesObject: AnyObject?
        let actionStatus = AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &actionNamesObject)
        if actionStatus != .success {
            // No zoom button means this window shouldn't be managed
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

        guard let observer = ensureObserver(for: pid, appElement: appElement) else {
            return
        }

        for notification in windowAccessibilityNotifications {
            let status = AXObserverAddNotification(observer, element, notification, observerRefcon)
            if status == .success || status == .notificationAlreadyRegistered {
                Logger.debug("Successfully registered notification '\(notification as String)' for window pid \(pid)")
                continue
            }
            Logger.debug("Failed to register \(notification) for pid \(pid), AX error \(status.rawValue)")
        }
    }

    private func ensureObserver(for pid: pid_t, appElement: AXUIElement) -> AXObserver? {
        if let observer = accessibilityObservers[pid] {
            return observer
        }

        var observer: AXObserver?
        let status = AXObserverCreate(pid, windowControllerObserverCallback, &observer)
        guard status == .success, let observer else {
            Logger.debug("Unable to create AXObserver for pid \(pid): \(status.rawValue)")
            return nil
        }

        accessibilityObservers[pid] = observer
        accessibilityApplications[pid] = appElement

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)

        for notification in applicationAccessibilityNotifications {
            let status = AXObserverAddNotification(observer, appElement, notification, observerRefcon)
            if status == .success || status == .notificationAlreadyRegistered {
                Logger.debug("Successfully registered application notification '\(notification as String)' for pid \(pid)")
                continue
            }
            Logger.debug("Failed to register application notification \(notification) for pid \(pid), AX error \(status.rawValue)")
        }

        return observer
    }

    private func managedWindow(matching element: AXUIElement) -> ManagedWindow? {
        for window in managedWindows.values {
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

            let appElement = accessibilityApplications[pid] ?? AXUIElementCreateApplication(pid)
            accessibilityApplications[pid] = appElement

            _ = captureWindowIfNeeded(
                element: element,
                pid: pid,
                appElement: appElement,
                allowReturningExisting: false,
                notifyDelegate: true
            )
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

            let appElement = accessibilityApplications[targetPid] ?? AXUIElementCreateApplication(targetPid)
            accessibilityApplications[targetPid] = appElement

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
            managedWindows.removeValue(forKey: managed.windowId)

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

        guard let observer = accessibilityObservers[pid] else {
            return
        }

        for notification in windowAccessibilityNotifications {
            AXObserverRemoveNotification(observer, element, notification)
        }

        let stillManaged = managedWindows.values.contains { window in
            guard case .accessibility(_, let otherPid, _) = window.backing else {
                return false
            }
            return otherPid == pid && window.windowId != managed.windowId
        }

        if !stillManaged {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
            accessibilityObservers.removeValue(forKey: pid)
            accessibilityApplications.removeValue(forKey: pid)
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

        var stale: [(Int, ManagedWindow)] = []

        for (windowId, managed) in managedWindows {
            guard case .accessibility(_, let pid, let windowNumber?) = managed.backing else {
                continue
            }

            let identifier = ExternalWindowIdentifier(pid: pid, windowNumber: windowNumber)
            // If the window is not in the actual windows from window server, it's been destroyed
            if !actualWindows.contains(identifier) {
                stale.append((windowId, managed))
            }
        }

        if stale.isEmpty {
            return []
        }

        var removedWindowIds: [Int] = []
        for (windowId, managed) in stale {
            Logger.debug("Detected destroyed external window \(windowId) (not in CGWindowList); pruning")
            removeAccessibilityTracking(for: managed)
            managedWindows.removeValue(forKey: windowId)
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

        var stale: [(Int, ManagedWindow)] = []

        for (windowId, managed) in managedWindows {
            guard case .accessibility(_, let windowPid, let windowNumber?) = managed.backing else {
                continue
            }

            // Only check windows for this specific PID
            guard windowPid == pid else {
                continue
            }

            // If the window number is not in the actual windows from window server, it's been destroyed
            if !actualWindowNumbers.contains(windowNumber) {
                stale.append((windowId, managed))
            }
        }

        if stale.isEmpty {
            return []
        }

        var removedWindowIds: [Int] = []
        for (windowId, managed) in stale {
            Logger.debug("Detected destroyed external window \(windowId) for pid \(pid) (not in CGWindowList); pruning")
            removeAccessibilityTracking(for: managed)
            managedWindows.removeValue(forKey: windowId)
            if let identifier = managed.externalIdentifier {
                externalWindows.removeValue(forKey: identifier)
            }
            removedWindowIds.append(windowId)
            Logger.debug("Pruned destroyed external window \(windowId)")
        }

        return removedWindowIds
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

    func constrainedPlaceholderSize(for windowId: Int, proposedSize: NSSize, currentSize: NSSize) -> NSSize {
        guard let managed = managedWindows[windowId],
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

        guard let managed = managedWindows[windowId], !managed.isPlaceholder else {
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
        return Array(managedWindows.values)
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
        guard let managed = managedWindows[windowId] else {
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
        guard let managed = managedWindows[windowId] else {
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
        guard let managed = managedWindows[windowId], !managed.isPlaceholder else {
            return
        }

        currentDraggingWindowId = windowId
        Logger.debug("User began dragging window \(windowId)")
        let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
        delegate?.windowManualMoveDidBegin(windowId: windowId, frame: accessibilityFrame)
    }

    func windowDidMove(windowId: Int) {
        guard currentDraggingWindowId == windowId,
              let managed = managedWindows[windowId],
              let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) else {
            return
        }
        delegate?.windowManualMoveDidUpdate(windowId: windowId, frame: accessibilityFrame)
    }
}
