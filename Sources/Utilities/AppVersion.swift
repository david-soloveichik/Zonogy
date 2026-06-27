/// Shared Zonogy version formatting for UI and logs.
import Foundation

enum AppVersion {
    /// Marketing version shown to users, e.g. "1.0".
    static var marketingVersion: String {
        infoString("CFBundleShortVersionString") ?? "1.0"
    }

    /// Parenthetical build detail like "805 · ef8f4d6", combining the build number
    /// (git commit count in CFBundleVersion) and the short git hash. Both are stamped
    /// into Info.plist by scripts/build.sh at package time. Returns nil when running
    /// outside a packaged bundle (e.g. plain `swift build`) so the version reads as a
    /// clean "1.0" during development. The source plist seeds CFBundleVersion equal to
    /// the marketing version, so an unstamped bundle also shows no build number.
    static var buildDetail: String? {
        let build = infoString("CFBundleVersion").flatMap { $0 == marketingVersion ? nil : $0 }
        let hash = infoString("ZonogyGitHash")
        let parts = [build, hash].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Zonogy Window Manager 1.0 (805 · ef8f4d6)" for the General tab and logs.
    static var preferencesDisplayString: String {
        displayString(prefix: "Zonogy Window Manager")
    }

    /// "Zonogy 1.0 (805 · ef8f4d6)" for the menu bar's inactive title item.
    static var menuBarDisplayString: String {
        displayString(prefix: "Zonogy")
    }

    /// Joins a product-name prefix with the marketing version and optional build detail.
    private static func displayString(prefix: String) -> String {
        let base = "\(prefix) \(marketingVersion)"
        guard let detail = buildDetail else { return base }
        return "\(base) (\(detail))"
    }

    /// Reads an Info.plist string, treating missing or blank values as absent.
    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
