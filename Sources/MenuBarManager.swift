/// Manages the menu bar status item and its menu
import Foundation
import AppKit

protocol MenuBarManagerDelegate: AnyObject {
    func menuBarManagerDidRequestQuit()
}

class MenuBarManager {
    private var statusItem: NSStatusItem?
    weak var delegate: MenuBarManagerDelegate?

    init() {
        setupMenuBar()
    }

    deinit {
        tearDown()
    }

    private func setupMenuBar() {
        // Create status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let statusItem = statusItem else {
            Logger.debug("Failed to create status item")
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

        let quitItem = NSMenuItem(
            title: "Quit LatticeTopology",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        Logger.debug("Menu bar icon initialized")
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

        Logger.debug("Failed to load SVG icon from any search path")
        return nil
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
