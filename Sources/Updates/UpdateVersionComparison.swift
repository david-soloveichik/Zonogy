/// Pure version-ordering logic for the software update check.
///
/// Understands optional pre-release suffixes (like "1.0-beta.2") using Semantic Versioning
/// precedence, so a beta orders before its final release and successive betas order among
/// themselves.

import Foundation

enum UpdateVersionComparison {
    /// True when `releaseTag` (e.g. "v1.2", "1.2.3", or "1.2-beta.1") denotes a strictly newer
    /// version than `installed`. The numeric release is compared per dot-separated component
    /// ("1.10" > "1.9"; missing components count as 0). A version carrying a pre-release suffix
    /// ("1.2-beta.1") is older than the same version without one, and two pre-releases order by
    /// Semantic Versioning rules. Unparseable versions are never newer.
    static func isNewer(releaseTag: String, than installed: String) -> Bool {
        guard let release = SemanticVersion(releaseTag),
              let current = SemanticVersion(installed) else { return false }
        return current < release
    }

    /// "v1.2-beta.1" → "1.2-beta.1": the user-facing version for a release tag.
    static func normalized(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        return text
    }
}

/// A parsed version: a numeric release ("1.2" → [1, 2]) plus any dot-separated pre-release
/// identifiers following a "-" ("1.2-beta.1" → ["beta", "1"]). No identifiers means a final release.
private struct SemanticVersion: Comparable {
    let release: [Int]
    let prerelease: [String]

    /// Parses "v1.2.3-beta.1". Returns nil when the release has a non-integer component or a
    /// pre-release identifier is empty, so a malformed tag is never treated as an update.
    init?(_ version: String) {
        let text = UpdateVersionComparison.normalized(version)
        guard !text.isEmpty else { return nil }

        let releaseText: Substring
        if let dash = text.firstIndex(of: "-") {
            releaseText = text[..<dash]
            let identifiers = text[text.index(after: dash)...]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard !identifiers.isEmpty, !identifiers.contains(where: \.isEmpty) else { return nil }
            prerelease = identifiers
        } else {
            releaseText = text[...]
            prerelease = []
        }

        var components: [Int] = []
        for part in releaseText.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Self.numericValue(of: part) else { return nil }
            components.append(value)
        }
        guard !components.isEmpty else { return nil }
        release = components
    }

    /// The value of a digit-only ("[0-9]+") identifier, or nil for anything else — empty,
    /// signed (`Int` alone would accept "+1"/"-1"), or containing non-digits. Used both to
    /// parse numeric release components and to tell numeric pre-release identifiers from
    /// alphanumeric ones, which Semantic Versioning orders differently.
    private static func numericValue<S: StringProtocol>(of identifier: S) -> Int? {
        guard !identifier.isEmpty, identifier.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(identifier)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        // Numeric release components decide first; a missing component counts as zero.
        for index in 0..<max(lhs.release.count, rhs.release.count) {
            let left = index < lhs.release.count ? lhs.release[index] : 0
            let right = index < rhs.release.count ? rhs.release[index] : 0
            if left != right { return left < right }
        }
        // Same release: a final version outranks any pre-release of it.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        // Two pre-releases: compare identifiers left to right.
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            // With all preceding identifiers equal, the shorter list orders first.
            guard index < lhs.prerelease.count else { return true }
            guard index < rhs.prerelease.count else { return false }
            let left = lhs.prerelease[index], right = rhs.prerelease[index]
            if left == right { continue }
            switch (Self.numericValue(of: left), Self.numericValue(of: right)) {
            case let (leftValue?, rightValue?): return leftValue < rightValue  // both numeric
            case (_?, nil): return true                                        // numeric ranks below alphanumeric
            case (nil, _?): return false
            case (nil, nil): return left < right                               // alphanumeric compared lexically
            }
        }
        return false
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        // Consistent with `<` and its zero-padding of missing release components.
        !(lhs < rhs) && !(rhs < lhs)
    }
}
