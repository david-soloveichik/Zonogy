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

struct PlaceholderResizeAxes: OptionSet {
    let rawValue: Int

    static let horizontal = PlaceholderResizeAxes(rawValue: 1 << 0)
    static let vertical = PlaceholderResizeAxes(rawValue: 1 << 1)
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
        kAXWindowCreatedNotification as CFString
    ]
    private lazy var observerRefcon: UnsafeMutableRawPointer = {
        Unmanaged.passUnretained(self).toOpaque()
    }()
    weak var delegate: WindowControllerDelegate?
    private var currentDraggingWindowId: Int?
    private var mouseUpMonitor: Any?
    private var mouseUpGlobalMonitor: Any?
    private var resizingWindowId: Int?

    init(ignoredBundleIdentifiers: Set<String> = []) {
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
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

        let managed = ManagedWindow(
            windowId: windowId,
            backing: .appKit(window),
            isPlaceholder: true
        )
        managedWindows[windowId] = managed

        Logger.debug("Created placeholder window \(windowId) for zone \(zoneIndex)")
        return managed
    }

    @objc private func handlePlaceholderClose(_ sender: NSButton) {
        let zoneIndex = sender.tag
        Logger.debug("Placeholder close button clicked for zone \(zoneIndex)")
        delegate?.placeholderCloseRequested(zoneIndex: zoneIndex)
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

        _ = ensureObserver(for: pid, appElement: appElement)

        var windowsObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
        guard status == .success, let windowsObject else {
            if status != .success {
                Logger.debug("Failed to enumerate windows for pid \(pid) (AX error \(status.rawValue))")
            }
            return []
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

    /// Show a window at the specified frame
    func showWindow(_ managedWindow: ManagedWindow, at frame: CGRect) {
        switch managedWindow.backing {
        case .appKit(let window):
            window.setFrame(frame, display: true)
            window.orderFront(nil)
        case .accessibility(let element, _, _):
            performProgrammaticUpdate(for: managedWindow.windowId) {
                _ = setAccessibilityFrame(element: element, frame: frame)
            }
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        Logger.debug("Showed window \(managedWindow.windowId) at frame \(frame)")
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

    /// Resize and reposition a window to match a frame
    func moveWindow(_ managedWindow: ManagedWindow, to frame: CGRect) {
        switch managedWindow.backing {
        case .appKit(let window):
            window.setFrame(frame, display: true, animate: false)
        case .accessibility(let element, _, _):
            performProgrammaticUpdate(for: managedWindow.windowId) {
                _ = setAccessibilityFrame(element: element, frame: frame)
            }
        }
        Logger.debug("Moved window \(managedWindow.windowId) to frame \(frame)")
    }

    private func performProgrammaticUpdate(for windowId: Int, _ block: () -> Void) {
        programmaticUpdateWindowIds.insert(windowId)
        block()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
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
            return subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String
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

        guard let managed = managedWindow(matching: element) else {
            return
        }

        switch notificationName {
        case axDestroyedNotification:
            Logger.debug("External window \(managed.windowId) destroyed, notifying delegate")
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
            delegate?.windowManualMoveDidEnd(windowId: managed.windowId, frame: managed.actualFrame)

        case axResizedNotificationName:
            guard !programmaticUpdateWindowIds.contains(managed.windowId) else {
                return
            }
            Logger.debug("External window \(managed.windowId) resized by user")
            delegate?.windowManualResizeDidEnd(windowId: managed.windowId, frame: managed.actualFrame)

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
