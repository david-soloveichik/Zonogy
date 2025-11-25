/// Controls the preferences window with tabbed interface
import AppKit

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private var tabViewController: NSTabViewController?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Zonogy Preferences"
        window.center()

        super.init(window: window)

        setupTabViewController()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTabViewController() {
        let tabVC = NSTabViewController()
        tabVC.tabStyle = .toolbar

        // General tab
        let generalVC = GeneralPreferencesViewController()
        let generalItem = NSTabViewItem(viewController: generalVC)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        tabVC.addTabViewItem(generalItem)

        // Keyboard Shortcuts tab
        let shortcutsVC = KeyboardShortcutsViewController()
        let shortcutsItem = NSTabViewItem(viewController: shortcutsVC)
        shortcutsItem.label = "Keyboard Shortcuts"
        shortcutsItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard Shortcuts")
        tabVC.addTabViewItem(shortcutsItem)

        window?.contentViewController = tabVC
        self.tabViewController = tabVC
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
