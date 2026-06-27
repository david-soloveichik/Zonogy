/// Controls the preferences window with tabbed interface
import AppKit

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    /// Stable tag so other subsystems can recognize the Preferences window (e.g. to suppress
    /// zone resize bars while it is focused) without forcing this singleton to instantiate.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ZonogyPreferences")

    private var tabViewController: NSTabViewController?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 525),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Zonogy Preferences"
        window.identifier = Self.windowIdentifier
        window.level = .floating
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

        // Targeting tab
        let targetingVC = TargetingPreferencesViewController()
        let targetingItem = NSTabViewItem(viewController: targetingVC)
        targetingItem.label = "Destination"
        targetingItem.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Destination")
        tabVC.addTabViewItem(targetingItem)

        // Keyboard Shortcuts tab
        let shortcutsVC = KeyboardShortcutsViewController()
        let shortcutsItem = NSTabViewItem(viewController: shortcutsVC)
        shortcutsItem.label = "Shortcuts"
        shortcutsItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard Shortcuts")
        tabVC.addTabViewItem(shortcutsItem)

        // Exceptions tab
        let exceptionsVC = ExceptionsPreferencesViewController()
        let exceptionsItem = NSTabViewItem(viewController: exceptionsVC)
        exceptionsItem.label = "Exceptions"
        exceptionsItem.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Exceptions")
        tabVC.addTabViewItem(exceptionsItem)

        // Launcher tab
        let launcherVC = LauncherPreferencesViewController()
        let launcherItem = NSTabViewItem(viewController: launcherVC)
        launcherItem.label = "Launcher"
        launcherItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Launcher")
        tabVC.addTabViewItem(launcherItem)

        // WinShot Snapshots tab
        let winShotVC = WinShotSnapshotsPreferencesViewController()
        let winShotItem = NSTabViewItem(viewController: winShotVC)
        winShotItem.label = "Snapshots"
        winShotItem.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Snapshots")
        tabVC.addTabViewItem(winShotItem)

        // Debug tab
        let debugVC = DebugPreferencesViewController()
        let debugItem = NSTabViewItem(viewController: debugVC)
        debugItem.label = "Debug"
        debugItem.image = NSImage(systemSymbolName: "ladybug", accessibilityDescription: "Debug")
        tabVC.addTabViewItem(debugItem)

        window?.contentViewController = tabVC
        self.tabViewController = tabVC
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
