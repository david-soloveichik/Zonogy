/// Small AppKit fixture for comparing native Spaces with ordinary presentation full screen.
/// The same executable also supplies a separate guest app for external-window arrival tests.
import AppKit
import os

/// A focusable borderless window that can cover the menu-bar area as well as the desktop.
final class PresentationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class LabDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let isGuest = Bundle.main.bundleIdentifier?.hasSuffix(".guest") == true
    private let logger = Logger(subsystem: "com.dsemeas.zonogy.fullscreenlab", category: "fixture")
    private let surface = NSView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let displays = NSPopUpButton()
    private var window: NSWindow!
    private var presentationWindow: NSWindow?
    private var previousPresentationOptions: NSApplication.PresentationOptions = []
    private var afterNativeExit: (() -> Void)?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        makeMenu()
        window = NSWindow(
            contentRect: NSRect(x: 180, y: 180, width: 640, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Full Screen Lab"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.contentView = surface
        surface.wantsLayer = true
        surface.layer?.backgroundColor = (isGuest ? NSColor.systemTeal : NSColor.windowBackgroundColor).cgColor

        let heading = NSTextField(labelWithString: window.title)
        heading.font = .systemFont(ofSize: 30, weight: .semibold)
        status.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        status.alignment = .center
        let stack = NSStackView(views: [heading, status])
        stack.orientation = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, constant: -32)
        ])

        for (index, screen) in NSScreen.screens.enumerated() {
            displays.addItem(withTitle: "Display \(index): \(screen.localizedName)")
        }
        stack.addArrangedSubview(displays)
        if !isGuest {
            stack.addArrangedSubview(button("Native Full Screen", #selector(enterNative)))
            stack.addArrangedSubview(button("Non-native Full Screen", #selector(enterNonNative)))
            stack.addArrangedSubview(button("Return to Window (Esc)", #selector(returnToWindow)))
            stack.addArrangedSubview(button("Open / Restore Guest on Selected Display", #selector(openGuest)))
        } else {
            stack.addArrangedSubview(button("Move to Selected Display", #selector(moveToSelectedDisplay)))
            stack.addArrangedSubview(button("Minimize", #selector(minimizeGuest)))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        report("launched")
        let urls = pendingURLs
        pendingURLs.removeAll()
        application(NSApp, open: urls)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func makeMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = appMenu
        mainMenu.addItem(root)
        let actions: [(String, Selector, String)] = isGuest
            ? [("Minimize", #selector(minimizeGuest), "m")]
            : [("Return to Window", #selector(returnToWindow), "1"),
               ("Native Full Screen", #selector(enterNative), "2"),
               ("Non-native Full Screen", #selector(enterNonNative), "3"),
               ("Open / Restore Guest", #selector(openGuest), "n")]
        for (title, action, key) in actions {
            let item = appMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = mainMenu
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.returnToWindow()
            return nil
        }
    }

    private var selectedScreen: NSScreen? {
        let index = displays.indexOfSelectedItem
        return NSScreen.screens.indices.contains(index) ? NSScreen.screens[index] : NSScreen.screens.first
    }

    @objc private func moveToSelectedDisplay() {
        guard let screen = selectedScreen else { return }
        let available = screen.visibleFrame
        let size = NSSize(width: min(window.frame.width, available.width),
                          height: min(window.frame.height, available.height))
        window.setFrame(NSRect(x: available.midX - size.width / 2,
                               y: available.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
    }

    /// Native transitions finish through the window delegate, with no settling delay.
    private func afterReturningToWindow(_ action: @escaping () -> Void) {
        if let presentationWindow {
            window.contentView = surface
            presentationWindow.close()
            self.presentationWindow = nil
            NSApp.presentationOptions = previousPresentationOptions
        }
        if window.styleMask.contains(.fullScreen) {
            afterNativeExit = action
            window.toggleFullScreen(nil)
        } else {
            action()
        }
    }

    @objc private func enterNative() {
        guard !window.styleMask.contains(.fullScreen) else { return }
        afterReturningToWindow { [self] in
            moveToSelectedDisplay()
            window.makeKeyAndOrderFront(nil)
            // Let AppKit finish assigning the moved window to its display before entering.
            DispatchQueue.main.async { [self] in
                guard presentationWindow == nil, !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }

    @objc private func enterNonNative() {
        guard presentationWindow == nil else { return }
        afterReturningToWindow { [self] in
            guard let screen = selectedScreen else { return }
            let presentation = PresentationWindow(
                contentRect: screen.frame, styleMask: .borderless,
                backing: .buffered, defer: false
            )
            presentation.title = "\(window.title) — Non-native"
            presentation.isReleasedWhenClosed = false
            presentation.collectionBehavior = [.fullScreenNone]
            presentation.delegate = self
            presentationWindow = presentation
            previousPresentationOptions = NSApp.presentationOptions
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            // Normal level, real AX attributes, and the current Space: other apps can cover it.
            presentation.contentView = surface
            presentation.makeKeyAndOrderFront(nil)
            report("entered non-native")
        }
    }

    @objc private func returnToWindow() {
        afterReturningToWindow { [self] in
            window.makeKeyAndOrderFront(nil)
            report("returned to window")
        }
    }

    @objc private func minimizeGuest() {
        window.miniaturize(nil)
    }

    @objc private func openGuest() {
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Full Screen Guest.app")
        let url = URL(string: "zonogy-fullscreen-guest://show?screen=\(max(0, displays.indexOfSelectedItem))")!
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: .init()) { [logger] _, error in
            if let error { logger.error("Guest launch failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// URL commands let a test driver use real app actions instead of synthetic AX attributes.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Launch Services can deliver the first command before didFinishLaunching.
        guard window != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "screen" })?.value,
               let index = Int(value), NSScreen.screens.indices.contains(index) {
                displays.selectItem(at: index)
            }
            switch url.host {
            case "native" where !isGuest: enterNative()
            case "non-native" where !isGuest: enterNonNative()
            case "window": returnToWindow()
            case "guest" where !isGuest: openGuest()
            case "minimize" where isGuest: minimizeGuest()
            case "show" where isGuest:
                moveToSelectedDisplay()
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            case "quit": application.terminate(nil)
            default: break
            }
            report("command \(url.host ?? "unknown")")
        }
    }

    private func report(_ event: String) {
        guard let visibleWindow = surface.window ?? window else { return }
        let mode = presentationWindow != nil ? "Non-native full screen" :
            window.styleMask.contains(.fullScreen) ? "Native full screen" : "Windowed"
        let frame = visibleWindow.frame
        let index = NSScreen.screens.firstIndex(where: { $0 == visibleWindow.screen }).map(String.init) ?? "?"
        status.stringValue = "\(mode) · Display \(index)\n\(Int(frame.width)) × \(Int(frame.height)) · Window \(visibleWindow.windowNumber)"
        logger.info("\(event, privacy: .public): \(self.isGuest ? "guest" : "host", privacy: .public) \(mode, privacy: .public) display=\(index, privacy: .public) window=\(visibleWindow.windowNumber) minimized=\(visibleWindow.isMiniaturized) frame=\(NSStringFromRect(frame), privacy: .public)")
    }

    func windowDidEnterFullScreen(_ notification: Notification) { report("entered native") }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { report("native entry failed") }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        afterNativeExit = nil
        report("native exit failed")
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        let action = afterNativeExit
        afterNativeExit = nil
        action?()
        report("exited native")
    }
    func windowDidResize(_ notification: Notification) { report("resized") }
    func windowDidMove(_ notification: Notification) { report("moved") }
    func windowDidBecomeKey(_ notification: Notification) { report("focused") }
    func windowDidMiniaturize(_ notification: Notification) { report("minimized") }
    func windowDidDeminiaturize(_ notification: Notification) { report("restored") }
    func applicationWillTerminate(_ notification: Notification) {
        if presentationWindow != nil { NSApp.presentationOptions = previousPresentationOptions }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = LabDelegate()
application.delegate = delegate
application.run()
