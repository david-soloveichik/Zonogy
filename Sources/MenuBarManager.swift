/// Manages the menu bar status item and its menu
import Foundation
import AppKit

protocol MenuBarManagerDelegate: AnyObject {
    func menuBarManagerDidRequestQuit()
    func menuBarManagerDidRequestPreferences()
    func menuBarManagerDidRequestSaveSnapshot()
    func menuBarManagerDidRequestClearAllSnapshots()
    func menuBarManagerDidRequestCheckForUpdates()
}

/// Manages the menu bar status item, including visual state (e.g. dimming during sleep/wake) and its menu.
class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem?
    private var isDimmed: Bool = false
    private var saveSnapshotItem: NSMenuItem?
    private var checkForUpdatesItem: NSMenuItem?
    weak var delegate: MenuBarManagerDelegate?

    override init() {
        super.init()
        setupMenuBar()
    }

    deinit {
        tearDown()
    }

    private func setupMenuBar() {
        // Create status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let statusItem = statusItem else {
            Logger.error("Failed to create status item")
            return
        }

        // Set the icon
        if let icon = createIconImage() {
            statusItem.button?.image = icon
            statusItem.button?.imageScaling = .scaleProportionallyDown
        } else {
            // Fallback to text if icon loading fails
            statusItem.button?.title = "LT"
            Logger.debug("Using text fallback for menu bar icon")
        }

        // Create the menu
        let menu = NSMenu()
        menu.delegate = self

        // Inactive header showing the app name and version. A nil action leaves it
        // grayed out under NSMenu's automatic item enabling.
        let versionItem = NSMenuItem(
            title: AppVersion.menuBarDisplayString,
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        checkForUpdatesItem = addItem(to: menu, title: "Check for Updates...", action: #selector(handleCheckForUpdates))
        addItem(to: menu, title: "Preferences...", action: #selector(handlePreferences), keyEquivalent: ",")

        menu.addItem(NSMenuItem.separator())

        addItem(to: menu, title: "Clear All Snapshots", action: #selector(handleClearAllSnapshots))
        saveSnapshotItem = addItem(to: menu, title: "Save Snapshot", action: #selector(handleSaveSnapshot))
        updateSaveSnapshotShortcut()

        menu.addItem(NSMenuItem.separator())

        // Feedback comes in two flavors: public on the issue tracker, or private by email.
        let helpMenu = NSMenu()
        addItem(to: helpMenu, title: "GitHub", action: #selector(handleOpenGitHub))
        addItem(to: helpMenu, title: "Feedback on GitHub...", action: #selector(handleFeedbackOnGitHub))
        addItem(to: helpMenu, title: "Feedback by Email...", action: #selector(handleFeedbackByEmail))

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        menu.addItem(helpItem)
        menu.setSubmenu(helpMenu, for: helpItem)

        menu.addItem(NSMenuItem.separator())

        addItem(to: menu, title: "Quit Zonogy", action: #selector(handleQuit), keyEquivalent: "q")

        statusItem.menu = menu

        // Ensure initial appearance is not dimmed.
        setDimmed(false)

        Logger.debug("Menu bar icon initialized")
    }

    /// Appends an item targeting this manager, and returns it for the few callers that keep a
    /// reference to retitle or re-shortcut it later.
    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func createIconImage() -> NSImage? {
        // Try to locate the SVG icon file
        let iconFileName = "icon_menubar.svg"

        // Search in multiple locations
        let searchPaths = [
            // Resources directory relative to working directory (for development)
            "Resources/\(iconFileName)",
            // Resources directory relative to executable (for deployed binary)
            (ProcessInfo.processInfo.arguments[0] as NSString).deletingLastPathComponent + "/../Resources/\(iconFileName)",
            // Same directory as executable
            (ProcessInfo.processInfo.arguments[0] as NSString).deletingLastPathComponent + "/\(iconFileName)"
        ]

        for path in searchPaths {
            let expandedPath = (path as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: expandedPath),
               let image = NSImage(contentsOfFile: expandedPath) {
                Logger.debug("Loaded icon from: \(expandedPath)")
                // Make it a template image so it adapts to dark/light mode
                image.isTemplate = true
                return image
            }
        }

        Logger.error("Failed to load SVG icon from any search path")
        return nil
    }

    /// Updates the dimming state of the menu bar icon.
    /// When dimmed, the icon's alpha is reduced to provide feedback during sleep/wake transitions.
    func setDimmed(_ dimmed: Bool) {
        guard dimmed != isDimmed else { return }
        isDimmed = dimmed

        guard let button = statusItem?.button else { return }
        button.alphaValue = dimmed ? 0.25 : 1.0
    }

    @objc private func handlePreferences() {
        Logger.debug("Preferences requested from menu bar")
        delegate?.menuBarManagerDidRequestPreferences()
    }

    @objc private func handleCheckForUpdates() {
        Logger.debug("Check for updates requested from menu bar")
        delegate?.menuBarManagerDidRequestCheckForUpdates()
    }

    /// Retitles the update item when a newer version is known, so the menu doubles as a
    /// passive update hint. Pass nil to restore the plain "Check for Updates..." item.
    func setAvailableUpdateVersion(_ version: String?) {
        checkForUpdatesItem?.title = version.map { "Update Available (\($0))..." } ?? "Check for Updates..."
    }

    @objc private func handleSaveSnapshot() {
        Logger.debug("Save snapshot requested from menu bar")
        delegate?.menuBarManagerDidRequestSaveSnapshot()
    }

    @objc private func handleClearAllSnapshots() {
        Logger.debug("Clear all snapshots requested from menu bar")
        delegate?.menuBarManagerDidRequestClearAllSnapshots()
    }

    @objc private func handleOpenGitHub() {
        AppLinks.open(AppLinks.repository)
    }

    @objc private func handleFeedbackOnGitHub() {
        AppLinks.open(AppLinks.feedbackIssue)
    }

    @objc private func handleFeedbackByEmail() {
        AppLinks.open(AppLinks.feedbackEmail)
    }

    /// Reflects the current (user-configurable) Save Snapshot shortcut beside its menu item so the
    /// menu always matches Preferences. Clears the equivalent when the action has no shortcut.
    private func updateSaveSnapshotShortcut() {
        guard let item = saveSnapshotItem else { return }
        if let shortcut = KeyboardShortcutPreferences.shared.shortcut(for: .saveWinShotSnapshot),
           let equivalent = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    @objc private func handleQuit() {
        Logger.debug("Quit requested from menu bar")
        delegate?.menuBarManagerDidRequestQuit()
        NSApplication.shared.terminate(nil)
    }

    func tearDown() {
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }
}

extension MenuBarManager: NSMenuDelegate {
    /// The Save Snapshot shortcut can change in Preferences, so refresh it each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateSaveSnapshotShortcut()
    }
}
