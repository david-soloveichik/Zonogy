/// Coordinates the Launcher UI, key monitoring, and window/app selection

import AppKit
import SwiftUI

protocol LauncherControllerDelegate: AnyObject {
    /// Called when a window is selected from the window list
    func launcherController(_ controller: LauncherController, didSelectWindow window: LauncherWindowItem)

    /// Called when an application should be launched
    func launcherController(_ controller: LauncherController, didLaunchApp url: URL)

    /// Called when an app header is selected (activate app without targeting a window)
    func launcherController(_ controller: LauncherController, didActivateApp bundleIdentifier: String)

    /// Starts a Launcher row drag session and returns the effective payload that should stay attached to it.
    func launcherController(_ controller: LauncherController, beginDrag payload: LauncherDragPayload) -> LauncherDragPayload?

    /// Called repeatedly during a Launcher row drag session as the cursor moves.
    func launcherControllerDidUpdateDrag(_ controller: LauncherController, cursorPointAX: CGPoint?)

    /// Called when a Launcher row drag session ends. Returns true if the drop resolved successfully.
    func launcherController(_ controller: LauncherController, didEndDrag payload: LauncherDragPayload, cursorPointAX: CGPoint?) -> Bool

    /// Called when the launcher is explicitly cancelled.
    func launcherControllerDidCancel(_ controller: LauncherController)

    /// Called when the launcher is dismissed
    func launcherControllerDidDismiss(_ controller: LauncherController)

    /// Returns the frame of the targeted zone in screen coordinates, and its screen descriptor
    func targetedZoneFrame() -> (CGRect, ScreenDescriptor)?

    /// Returns the screen ID for the targeted zone (for fallback centering)
    func targetedScreenId() -> CGDirectDisplayID?

    /// Provides window information for the launcher
    var launcherWindowProvider: LauncherWindowProvider { get }

    /// Returns the PID of the application that owns the menu bar (frontmost non-Zonogy app)
    func menuBarOwnerPid() -> pid_t?

    /// Returns the current cursor point in accessibility coordinates.
    func launcherCurrentCursorAccessibilityPoint() -> CGPoint?

    /// Called when the user presses a zone-removal shortcut (Cmd-M or Cmd-W) while the Launcher is open
    func launcherControllerDidRequestRemoveZone(_ controller: LauncherController)
}

final class LauncherController {
    private enum CloseReason {
        case cancelled
        case dismissed
    }

    weak var delegate: LauncherControllerDelegate?

    private static let forwardedShortcutEventMarker: Int64 = 0x5A4E4759

    private var window: LauncherWindow?
    private var model: LauncherModel?
    private var hostingView: NSHostingView<LauncherView>?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var clickMonitor: ClickOutsideMonitor?
    private var appTerminationObserver: Any?
    private var lastAnchor: Anchor?
    private var autoShowGraceUntil: Date?
    private var pendingAutoShowGraceOnOpen = false
    private var clickSuppressionGate = LauncherClickSuppressionGate()
    private lazy var rowDragController = CursorDrivenRowDragController<LauncherDragPayload>(
        logPrefix: "Launcher",
        currentCursorAXProvider: { [weak self] in
            self?.delegate?.launcherCurrentCursorAccessibilityPoint()
        },
        onDidBeginDrag: { _ in },
        onDidUpdateDrag: { [weak self] cursorPointAX in
            guard let self else { return }
            self.delegate?.launcherControllerDidUpdateDrag(self, cursorPointAX: cursorPointAX)
        },
        onDidEndDrag: { [weak self] payload, cursorPointAX in
            guard let self else { return }
            let didResolveDrop = self.delegate?.launcherController(self, didEndDrag: payload, cursorPointAX: cursorPointAX) ?? false
            self.completeRowDrag(didResolveDrop: didResolveDrop)
        }
    )

    private(set) var isActive = false

    /// Grace period duration for auto-show (prevents immediate dismissal from macOS auto-focus)
    private static let autoShowGracePeriod: TimeInterval = 0.5

    private enum Anchor: Equatable {
        case zone(frame: CGRect, screenId: CGDirectDisplayID)
        case screen(screenId: CGDirectDisplayID)
        case main
    }

    /// Show the Launcher with a grace period that prevents immediate dismissal from focus changes.
    /// Use this when auto-showing (e.g., zone became empty) to handle macOS auto-focus behavior.
    func autoShow() {
        // Start the grace timer only after the panel is actually shown.
        pendingAutoShowGraceOnOpen = true
        show()
    }

    /// Returns true if the Launcher is within its auto-show grace period.
    /// During this period, focus-based dismissals should be skipped.
    var isInAutoShowGracePeriod: Bool {
        guard let graceUntil = autoShowGraceUntil else { return false }
        return Date() < graceUntil
    }

    func armInheritedClickSuppression(at screenPoint: CGPoint = NSEvent.mouseLocation) {
        clickSuppressionGate.arm(at: screenPoint)
        Logger.debug("Launcher: Armed inherited click suppression at \(screenPoint)")
    }

    func show() {
        let shouldStartAutoShowGrace = pendingAutoShowGraceOnOpen
        pendingAutoShowGraceOnOpen = false

        guard let delegate = delegate else {
            Logger.debug("Launcher: Cannot show - no delegate")
            return
        }

        // Create model with Zonogy integration (must be on main actor)
        MainActor.assumeIsolated {
            let model = LauncherModel()
            model.windowProvider = delegate.launcherWindowProvider
            self.model = model

            // Create window if needed
            if window == nil {
                window = LauncherWindow()
            }

            // Create the SwiftUI view
            let launcherView = LauncherView(
                model: model,
                onDismiss: { [weak self] in self?.cancel() },
                onLaunchApp: { [weak self] url in self?.handleAppLaunch(url: url) },
                onSelectWindow: { [weak self] window in self?.handleWindowSelection(window: window) },
                onActivateApp: { [weak self] bundleId in self?.handleAppActivation(bundleId: bundleId) },
                onBeginDrag: { [weak self] payload in self?.beginDrag(payload: payload) }
            )

            let hostingView = NSHostingView(rootView: launcherView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            self.hostingView = hostingView

            // Add hosting view to the visual effect view
            if let visualEffectView = window?.visualEffectView {
                visualEffectView.subviews.forEach { $0.removeFromSuperview() }
                visualEffectView.addSubview(hostingView)
                NSLayoutConstraint.activate([
                    hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
                    hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
                    hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
                    hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
                ])
            }

            // Position window on targeted zone
            if let (zoneFrame, descriptor) = delegate.targetedZoneFrame() {
                window?.centerOnZone(frame: zoneFrame, screenDescriptor: descriptor)
                self.lastAnchor = .zone(frame: zoneFrame, screenId: descriptor.displayId)
            } else if let screenId = delegate.targetedScreenId() {
                // No zone frame means floating zone is targeted - position lower on screen
                window?.centerOnScreen(screenId, forFloatingZone: true)
                self.lastAnchor = .screen(screenId: screenId)
            } else {
                // Fall back to main screen
                if NSScreen.main != nil {
                    window?.center()
                    self.lastAnchor = .main
                }
            }

            window?.makeKeyAndOrderFront(nil)

            if shouldStartAutoShowGrace {
                self.autoShowGraceUntil = Date().addingTimeInterval(Self.autoShowGracePeriod)
            } else {
                self.autoShowGraceUntil = nil
            }
        }

        startKeyMonitor()
        startMouseMonitor()
        startClickMonitor()
        startAppTerminationObserver()

        isActive = true
        Logger.debug("Launcher: Opened")
    }

    func hide() {
        completeClose(reason: .dismissed)
    }

    func cancel() {
        completeClose(reason: .cancelled)
    }

    private func completeClose(reason: CloseReason) {
        guard isActive else {
            return
        }

        tearDownVisibleLauncherUI()
        Logger.debug("Launcher: Closed")

        if reason == .cancelled {
            delegate?.launcherControllerDidCancel(self)
        }
        delegate?.launcherControllerDidDismiss(self)
    }

    private func tearDownVisibleLauncherUI() {
        stopKeyMonitor()
        stopMouseMonitor()
        stopClickMonitor()
        stopAppTerminationObserver()

        window?.orderOut(nil)
        hostingView = nil
        model = nil
        lastAnchor = nil
        pendingAutoShowGraceOnOpen = false
        autoShowGraceUntil = nil
        clickSuppressionGate.clear()

        isActive = false
    }

    private func beginDrag(payload: LauncherDragPayload) {
        guard isActive,
              let delegate,
              let resolvedPayload = delegate.launcherController(self, beginDrag: payload) else {
            return
        }

        tearDownVisibleLauncherUI()
        Logger.debug("Launcher: Closed for drag")

        rowDragController.beginDrag(
            for: resolvedPayload,
            title: resolvedPayload.previewTitle,
            initialCursorPointCocoa: NSEvent.mouseLocation,
            driveViaMouseMonitors: true
        )
    }

    private func completeRowDrag(didResolveDrop: Bool) {
        if didResolveDrop {
            Logger.debug("Launcher: Drag completed")
            delegate?.launcherControllerDidDismiss(self)
            return
        }

        Logger.debug("Launcher: Drag cancelled")
        delegate?.launcherControllerDidCancel(self)
        delegate?.launcherControllerDidDismiss(self)
    }

    func repositionToCurrentTarget() {
        guard isActive,
              let delegate,
              let window else {
            return
        }

        if let (zoneFrame, descriptor) = delegate.targetedZoneFrame() {
            window.centerOnZone(frame: zoneFrame, screenDescriptor: descriptor)
            lastAnchor = .zone(frame: zoneFrame, screenId: descriptor.displayId)
        } else if let screenId = delegate.targetedScreenId() {
            // No zone frame means floating zone is targeted - position lower on screen
            window.centerOnScreen(screenId, forFloatingZone: true)
            lastAnchor = .screen(screenId: screenId)
        } else {
            if NSScreen.main != nil {
                window.center()
            }
            lastAnchor = .main
        }

        refreshKeyWindowIfActive()
    }

    /// Refreshes Launcher keyboard focus during ordinary UI repositioning without activating Zonogy.
    private func refreshKeyWindowIfActive() {
        MainActor.assumeIsolated {
            guard self.isActive, let window = self.window else { return }

            window.makeKeyAndOrderFront(nil)
            self.model?.requestSearchFieldFocus()
        }
    }

    /// Makes the Launcher window key after system events that may have broken the non-activating panel focus path.
    /// Call this only for wake/system recovery cases where ordinary `makeKeyAndOrderFront` is insufficient.
    func makeKeyIfActive() {
        guard isActive, window != nil else { return }

        // After wake from sleep, the nonactivatingPanel may not properly receive keyboard
        // focus with just makeKeyAndOrderFront. We need to also activate the app.
        // NSApp.activate is asynchronous, so we must defer makeKeyAndOrderFront until
        // the next run loop iteration when the app will be active.
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, let window = self.window else { return }
            window.makeKeyAndOrderFront(nil)
            self.model?.requestSearchFieldFocus()
            Logger.debug("Launcher: Made key after system event - isNowKey:\(window.isKeyWindow)")
        }
    }

    func repositionIfNeeded() {
        guard isActive,
              let delegate,
              let window else {
            return
        }

        let zoneInfo = delegate.targetedZoneFrame()
        let screenId = delegate.targetedScreenId()

        let newAnchor: Anchor
        if let (zoneFrame, descriptor) = zoneInfo {
            newAnchor = .zone(frame: zoneFrame, screenId: descriptor.displayId)
        } else if let screenId {
            newAnchor = .screen(screenId: screenId)
        } else {
            newAnchor = .main
        }

        guard newAnchor != lastAnchor else {
            return
        }

        if let (zoneFrame, descriptor) = zoneInfo {
            window.centerOnZone(frame: zoneFrame, screenDescriptor: descriptor)
        } else if let screenId {
            // No zone frame means floating zone is targeted - position lower on screen
            window.centerOnScreen(screenId, forFloatingZone: true)
        } else {
            if NSScreen.main != nil {
                window.center()
            }
        }

        lastAnchor = newAnchor
        refreshKeyWindowIfActive()
    }

    // MARK: - Event Handling

    private func handleAppLaunch(url: URL) {
        hide()
        // Dispatch async to let the UI hide before doing work
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.launcherController(self, didLaunchApp: url)
        }
    }

    private func handleWindowSelection(window: LauncherWindowItem) {
        hide()
        // Dispatch async to let the UI hide before doing work
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.launcherController(self, didSelectWindow: window)
        }
    }

    private func handleAppActivation(bundleId: String) {
        hide()
        // Dispatch async to let the UI hide before doing work
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.launcherController(self, didActivateApp: bundleId)
        }
    }

    // MARK: - Key Monitoring

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isActive else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func startMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            guard let self = self else { return event }
            return self.handleMouseEvent(event) ? nil : event
        }
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func handleMouseEvent(_ event: NSEvent) -> Bool {
        guard clickSuppressionGate.isArmed else {
            return false
        }

        let screenPoint = screenPoint(for: event)
        switch event.type {
        case .mouseMoved, .leftMouseDragged:
            clickSuppressionGate.notePointerLocation(screenPoint)
            return false
        case .leftMouseDown, .leftMouseUp:
            let targetsLauncher = event.window === window || window?.frame.contains(screenPoint) == true
            if clickSuppressionGate.shouldSuppressLauncherPointerEvent(
                at: screenPoint,
                targetsLauncher: targetsLauncher
            ) {
                Logger.debug(
                    "Launcher: Suppressed inherited click-through type=\(event.type.rawValue) clickCount=\(event.clickCount)"
                )
                return true
            }
            return false
        default:
            return false
        }
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        if let eventWindow = event.window {
            return eventWindow.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        return MainActor.assumeIsolated {
            // Ignore our own synthetic forwarded shortcut events if they bounce back to Zonogy.
            if isForwardedShortcutEcho(event) {
                Logger.debug("Launcher: Ignored forwarded shortcut echo keyCode=\(event.keyCode)")
                return true
            }

            guard let model = model else { return false }

            switch event.keyCode {
            case 53:  // Escape
                switch model.mode {
                case .appList:
                    cancel()
                case .windowList:
                    model.exitWindowMode()
                }
                return true

            case 126:  // Up arrow
                switch model.mode {
                case .appList:
                    model.moveSelection(by: -1)
                case .windowList:
                    model.moveWindowSelection(by: -1)
                }
                return true

            case 125:  // Down arrow
                switch model.mode {
                case .appList:
                    model.moveSelection(by: 1)
                case .windowList:
                    model.moveWindowSelection(by: 1)
                }
                return true

            case 36:  // Return/Enter
                switch model.mode {
                case .appList:
                    if let url = model.recordAndGetSelectedItem() {
                        handleAppLaunch(url: url)
                    }
                case .windowList:
                    if model.isAppHeaderSelected {
                        if let bundleId = model.windowModeBundleIdentifier() {
                            handleAppActivation(bundleId: bundleId)
                        }
                    } else if let windowItem = model.selectedWindowItem() {
                        handleWindowSelection(window: windowItem)
                    }
                }
                return true

            case 48:  // Tab
                let shiftPressed = event.modifierFlags.contains(.shift)
                if shiftPressed {
                    // Shift-Tab: exit window mode if in it
                    if case .windowList = model.mode {
                        model.exitWindowMode()
                        return true
                    }
                } else {
                    // Tab: enter window mode if app has multiple windows
                    if case .appList = model.mode {
                        model.enterWindowMode()
                        return true
                    }
                }
                return false

            case 124:  // Right arrow
                // Right arrow at end of search string = Tab (drill into window list)
                if case .appList = model.mode, isCaretAtEndOfSearchField() {
                    model.enterWindowMode()
                    return true
                }
                return false

            case 123:  // Left arrow
                // Left arrow at start of search string = Escape (exit window list)
                if case .windowList = model.mode, isCaretAtStartOfSearchField() {
                    model.exitWindowMode()
                    return true
                }
                return false

            case 13:  // W key
                // Cmd-W removes the targeted zone (same as Cmd-M)
                if event.modifierFlags.contains(.command) {
                    delegate?.launcherControllerDidRequestRemoveZone(self)
                    return true
                }
                return false

            default:
                // Forward specific shortcuts to the menu bar owner app
                if forwardShortcutIfNeeded(event) {
                    return true
                }
                return false
            }
        }
    }

    // MARK: - Cursor Position Detection

    /// Returns true if the text cursor is at the end of the search field (or the field is empty).
    @MainActor
    private func isCaretAtEndOfSearchField() -> Bool {
        guard let model = model else { return true }

        // Try to get the field editor from the window.
        // The first responder during text editing is the shared field editor (NSTextView).
        if let window = window,
           let textView = window.firstResponder as? NSTextView {
            let selectedRange = textView.selectedRange()
            let textLength = textView.string.count
            // Caret is at end if selection starts at (or beyond) text length and nothing is selected
            return selectedRange.location >= textLength && selectedRange.length == 0
        }

        // Fallback: if query is empty, right arrow should drill down
        return model.query.isEmpty
    }

    /// Returns true if the text cursor is at the start of the search field (or the field is empty).
    @MainActor
    private func isCaretAtStartOfSearchField() -> Bool {
        guard let model = model else { return true }

        // Try to get the field editor from the window.
        if let window = window,
           let textView = window.firstResponder as? NSTextView {
            let selectedRange = textView.selectedRange()
            // Caret is at start if selection starts at position 0 and nothing is selected
            return selectedRange.location == 0 && selectedRange.length == 0
        }

        // Fallback: if query is empty, left arrow should exit window mode
        return model.query.isEmpty
    }

    // MARK: - Shortcut Forwarding

    /// Handles specific Launcher shortcuts by forwarding to the menu bar owner app.
    /// Returns true if the event was consumed (forwarded or intentionally dropped), false otherwise.
    private func forwardShortcutIfNeeded(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        let keyCode = event.keyCode

        // Check for specific shortcuts to forward.
        // Use lenient modifier matching: require certain modifiers, forbid others,
        // but ignore caps lock, function, numericPad, and help keys.
        let hasCommand = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)
        let hasOption = modifiers.contains(.option)
        let hasControl = modifiers.contains(.control)

        let shouldForward: Bool
        let forwardModifiers: CGEventFlags

        switch keyCode {
        case 45:  // N key
            if hasCommand && !hasOption && !hasControl {
                if hasShift {
                    // Cmd-Shift-N
                    shouldForward = true
                    forwardModifiers = [.maskCommand, .maskShift]
                } else {
                    // Cmd-N
                    shouldForward = true
                    forwardModifiers = [.maskCommand]
                }
            } else {
                shouldForward = false
                forwardModifiers = []
            }
        case 12:  // Q key
            if hasCommand && !hasShift && !hasOption && !hasControl {
                // Cmd-Q
                shouldForward = true
                forwardModifiers = [.maskCommand]
            } else {
                shouldForward = false
                forwardModifiers = []
            }
        case 31:  // O key
            if hasCommand && !hasShift && !hasOption && !hasControl {
                // Cmd-O
                shouldForward = true
                forwardModifiers = [.maskCommand]
            } else {
                shouldForward = false
                forwardModifiers = []
            }
        case 13:  // W key (Cmd-W handled above as zone removal)
            shouldForward = false
            forwardModifiers = []
        default:
            shouldForward = false
            forwardModifiers = []
        }

        guard shouldForward else { return false }

        guard let targetPid = delegate?.menuBarOwnerPid() else {
            Logger.debug("Launcher: Consumed shortcut keyCode=\(keyCode) because menu bar owner pid is unavailable")
            return true
        }

        if targetPid == getpid() {
            Logger.debug("Launcher: Consumed shortcut keyCode=\(keyCode) to prevent forwarding loop to Zonogy pid=\(targetPid)")
            return true
        }

        // Create and post CGEvent to the target application
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return false
        }

        keyDownEvent.flags = forwardModifiers
        keyUpEvent.flags = forwardModifiers
        keyDownEvent.setIntegerValueField(.eventSourceUserData, value: Self.forwardedShortcutEventMarker)
        keyUpEvent.setIntegerValueField(.eventSourceUserData, value: Self.forwardedShortcutEventMarker)

        keyDownEvent.postToPid(targetPid)
        keyUpEvent.postToPid(targetPid)

        Logger.debug("Launcher: Forwarded shortcut keyCode=\(keyCode) to pid=\(targetPid)")
        return true
    }

    private func isForwardedShortcutEcho(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else {
            return false
        }
        return cgEvent.getIntegerValueField(.eventSourceUserData) == Self.forwardedShortcutEventMarker
    }

    // MARK: - Click Outside Monitoring

    private func startClickMonitor() {
        guard let window = window else { return }
        let monitor = ClickOutsideMonitor(window: window, mode: .globalOnly) { [weak self] in
            guard let self, self.isActive else { return }
            self.cancel()
        }
        monitor.start()
        clickMonitor = monitor
    }

    private func stopClickMonitor() {
        clickMonitor?.stop()
        clickMonitor = nil
    }

    // MARK: - App Termination Observer

    /// Observes app termination to restore Launcher keyboard focus.
    /// When an app quits (e.g., via forwarded Cmd-Q), macOS activates another app,
    /// which can cause the Launcher's nonactivatingPanel to lose keyboard focus.
    /// This observer ensures we reclaim focus so the user can continue typing.
    private func startAppTerminationObserver() {
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.makeKeyIfActive()
        }
    }

    private func stopAppTerminationObserver() {
        if let observer = appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminationObserver = nil
        }
    }
}
