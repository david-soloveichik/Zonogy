import Foundation
import AppKit

/// Opens HTTP(S) links in a fresh window of the user's default browser.
final class BrowserLaunchController {
    private let workspace = NSWorkspace.shared
    private let automationQueue = DispatchQueue(label: "com.zonogy.browser-automation", qos: .userInitiated)

    private static let safariBundleId = "com.apple.Safari"
    private static let chromeBundleId = "com.google.Chrome"
    private static let edgeBundleId = "com.microsoft.edgemac"
    private static let firefoxBundleId = "org.mozilla.firefox"

    func openNewWindow(with url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            Logger.debug("Browser launch requested for non-web URL \(url.absoluteString)")
            return workspace.open(url)
        }

        guard let defaultBundleId = BrowserLaunchController.defaultBrowserBundleIdentifier() else {
            Logger.debug("Unable to resolve default browser bundle; falling back to NSWorkspace open")
            return workspace.open(url)
        }

        let escapedURL = appleScriptEscaped(url.absoluteString)

        switch defaultBundleId {
        case Self.safariBundleId:
            scheduleSafariLaunch(escapedURL: escapedURL, originalURL: url)
            return true
        case Self.chromeBundleId:
            return runChromiumScript(bundleId: defaultBundleId, escapedURL: escapedURL)
        case Self.edgeBundleId:
            return runChromiumScript(bundleId: defaultBundleId, escapedURL: escapedURL)
        case Self.firefoxBundleId:
            return launchFirefoxNewWindow(url: url)
        default:
            Logger.debug("Default browser \(defaultBundleId) not explicitly supported; using NSWorkspace open")
            return workspace.open(url)
        }
    }

    private func scheduleSafariLaunch(escapedURL: String, originalURL: URL) {
        automationQueue.async { [workspace] in
            if !self.runSafariScript(withEscapedURL: escapedURL) {
                Logger.debug("Safari automation failed; falling back to NSWorkspace open")
                _ = workspace.open(originalURL)
            }
        }
    }

    private func runSafariScript(withEscapedURL escapedURL: String) -> Bool {
        let source = """
        tell application id "\(Self.safariBundleId)"
            activate
            set newDocument to make new document
            ignoring application responses
                set URL of newDocument to "\(escapedURL)"
            end ignoring
        end tell
        """
        return runAppleScript(source: source)
    }

    private func runChromiumScript(bundleId: String, escapedURL: String) -> Bool {
        let source = """
        tell application id "\(bundleId)"
            activate
            set newWindow to make new window
            tell newWindow's active tab to set URL to "\(escapedURL)"
        end tell
        """
        return runAppleScript(source: source)
    }

    private func launchFirefoxNewWindow(url: URL) -> Bool {
        guard
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.firefoxBundleId),
            let executableURL = firefoxExecutableURL(from: appURL)
        else {
            Logger.debug("Firefox application URL not found; falling back to NSWorkspace open")
            return workspace.open(url)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-new-window", url.absoluteString]

        do {
            try process.run()
            return true
        } catch {
            Logger.debug("Failed to launch Firefox binary: \(error.localizedDescription)")
            return workspace.open(url)
        }
    }

    private func firefoxExecutableURL(from appURL: URL) -> URL? {
        let executableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("firefox", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: executableURL.path) {
            return executableURL
        }
        return nil
    }

    private func runAppleScript(source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else {
            Logger.debug("Failed to compile AppleScript for browser automation")
            return false
        }

        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)
        if let errorDict {
            Logger.debug("AppleScript execution failed: \(errorDict)")
            return false
        }
        return true
    }

    private func appleScriptEscaped(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return escaped
    }

    private static func defaultBrowserBundleIdentifier() -> String? {
        guard
            let testURL = URL(string: "http://example.com"),
            let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: testURL),
            let identifier = ApplicationIdentity.bundleIdentifier(forApplicationURL: applicationURL)
        else {
            return nil
        }
        return identifier
    }
}
