/// The icon for a Preferences → Exceptions entry. It stands for the installed apps the entry's bundle
/// identifier pattern matches: that app's icon for one, how many there are for several, and the bare
/// app symbol for none.

import AppKit

@MainActor
enum ExceptionAppIcon {
    static func image(forBundleIdentifier pattern: String, size: CGFloat) -> NSImage {
        let appURLs = installedApplicationURLs(matching: pattern)
        let image: NSImage
        switch appURLs.count {
        case 0:
            image = appSymbol() ?? NSImage()
        case 1:
            image = NSWorkspace.shared.icon(forFile: appURLs[0].path)
        default:
            image = countImage(appURLs.count, size: size)
        }
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// One app per matching bundle identifier. A plain bundle identifier asks LaunchServices, which
    /// also knows apps outside the folders the Launcher scans.
    private static func installedApplicationURLs(matching pattern: String) -> [URL] {
        guard BundleIdentifierPattern.wildcardPrefix(pattern) != nil else {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: pattern).map { [$0] } ?? []
        }
        return LauncherAppCache.shared.installedApplications
            .filter { BundleIdentifierPattern.matches(pattern, bundleIdentifier: $0.key) }
            .map(\.value)
    }

    private static func appSymbol() -> NSImage? {
        NSImage(systemSymbolName: "app", accessibilityDescription: "App")
    }

    /// The app symbol with `count` inside, drawn as a template like the symbol itself, so it takes
    /// the label color, and white on a selected row.
    private static func countImage(_ count: Int, size: CGFloat) -> NSImage {
        let symbol = appSymbol()
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Inset to about the size app icons show at
            let frame = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
            symbol?.draw(in: frame)
            var font = NSFont.systemFont(ofSize: frame.width * 0.55, weight: .semibold)
            let maxTextWidth = frame.width * 0.68
            let textWidth = NSAttributedString(string: "\(count)", attributes: [.font: font]).size().width
            if textWidth > maxTextWidth {
                font = NSFont.systemFont(ofSize: font.pointSize * maxTextWidth / textWidth, weight: .semibold)
            }
            let text = NSAttributedString(string: "\(count)", attributes: [.font: font, .foregroundColor: NSColor.black])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(count) apps"
        return image
    }
}
