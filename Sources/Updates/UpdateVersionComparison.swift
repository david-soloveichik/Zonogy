/// Pure version-ordering logic for the software update check.

import Foundation

enum UpdateVersionComparison {
    /// True when `releaseTag` (e.g. "v1.2" or "1.2.3") denotes a strictly newer version than
    /// `installed` (e.g. "1.0"). Components are compared numerically ("1.10" > "1.9"), missing
    /// components count as 0 ("1.0" equals "1.0.0"), and unparseable versions are never newer.
    static func isNewer(releaseTag: String, than installed: String) -> Bool {
        guard let release = numericComponents(of: releaseTag),
              let current = numericComponents(of: installed) else { return false }
        for index in 0..<max(release.count, current.count) {
            let releasePart = index < release.count ? release[index] : 0
            let currentPart = index < current.count ? current[index] : 0
            if releasePart != currentPart { return releasePart > currentPart }
        }
        return false
    }

    /// "v1.2" → "1.2": the user-facing version for a release tag.
    static func normalized(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        return text
    }

    /// Parses "v1.2.3" → [1, 2, 3]. Nil when any dot component is not a plain non-negative
    /// integer, so suffixed tags like "1.2-beta" are unparseable and never offered.
    private static func numericComponents(of version: String) -> [Int]? {
        let text = normalized(version)
        guard !text.isEmpty else { return nil }
        var components: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part), value >= 0 else { return nil }
            components.append(value)
        }
        return components
    }
}
