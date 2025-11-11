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
        let iconFileName = "LatticeTopology_CA110_regularized.svg"

        // Search in multiple locations
        let searchPaths = [
            // Resources directory relative to working directory (for development)
            "Resources/\(iconFileName)",
            // Resources directory relative to executable (for deployed binary)
            (ProcessInfo.processInfo.arguments[0] as NSString).deletingLastPathComponent + "/../Resources/\(iconFileName)",
            // Same directory as executable
            (ProcessInfo.processInfo.arguments[0] as NSString).deletingLastPathComponent + "/\(iconFileName)"
        ]

        var svgPath: String?
        for path in searchPaths {
            let expandedPath = (path as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: expandedPath) {
                svgPath = expandedPath
                Logger.debug("Found icon at: \(expandedPath)")
                break
            }
        }

        guard let finalPath = svgPath,
              let svgData = try? Data(contentsOf: URL(fileURLWithPath: finalPath)),
              let svgString = String(data: svgData, encoding: .utf8) else {
            Logger.debug("Failed to load SVG icon from any search path")
            return nil
        }

        // Parse the SVG to extract the rectangles and render them
        return renderSVGToImage(svgString: svgString)
    }

    private func renderSVGToImage(svgString: String) -> NSImage? {
        // Parse SVG dimensions
        guard let viewBoxRange = svgString.range(of: "viewBox=\"([^\"]+)\"", options: .regularExpression),
              let viewBoxString = svgString[viewBoxRange].split(separator: "\"").dropFirst().first else {
            return nil
        }

        let viewBoxComponents = viewBoxString.split(separator: " ").compactMap { Double($0) }
        guard viewBoxComponents.count == 4 else { return nil }

        let width = CGFloat(viewBoxComponents[2])
        let height = CGFloat(viewBoxComponents[3])

        // Create an image of appropriate size for menu bar (18x18 is standard)
        let imageSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: imageSize)

        image.lockFocus()

        // Clear background
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: imageSize).fill()

        // Calculate scale to fit the SVG into the menu bar icon
        let scale = min(imageSize.width / width, imageSize.height / height)

        // Center the icon
        let scaledWidth = width * scale
        let scaledHeight = height * scale
        let offsetX = (imageSize.width - scaledWidth) / 2
        let offsetY = (imageSize.height - scaledHeight) / 2

        // Parse and draw rectangles from SVG
        let rectPattern = "rect x=\"([0-9]+)\" y=\"([0-9]+)\" width=\"([0-9]+)\" height=\"([0-9]+)\" fill=\"([^\"]+)\""
        let regex = try? NSRegularExpression(pattern: rectPattern, options: [])
        let nsString = svgString as NSString
        let matches = regex?.matches(in: svgString, options: [], range: NSRange(location: 0, length: nsString.length)) ?? []

        for match in matches {
            guard match.numberOfRanges == 6 else { continue }

            let x = CGFloat(Int(nsString.substring(with: match.range(at: 1))) ?? 0)
            let y = CGFloat(Int(nsString.substring(with: match.range(at: 2))) ?? 0)
            let w = CGFloat(Int(nsString.substring(with: match.range(at: 3))) ?? 0)
            let h = CGFloat(Int(nsString.substring(with: match.range(at: 4))) ?? 0)
            let fill = nsString.substring(with: match.range(at: 5))

            // Skip white background
            if fill == "white" { continue }

            // Convert SVG coordinates to scaled image coordinates
            let scaledX = offsetX + (x * scale)
            let scaledY = offsetY + (y * scale)
            let scaledW = w * scale
            let scaledH = h * scale

            // Draw the rectangle (template images should be black/transparent)
            NSColor.black.setFill()
            let rect = NSRect(x: scaledX, y: imageSize.height - scaledY - scaledH, width: scaledW, height: scaledH)
            rect.fill()
        }

        image.unlockFocus()

        // Make it a template image so it adapts to dark/light mode
        image.isTemplate = true

        return image
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
