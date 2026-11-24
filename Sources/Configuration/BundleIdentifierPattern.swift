/// Bundle identifier patterns, as Exceptions entries use them: a pattern ending in `*` matches every
/// bundle identifier that starts with the text before the `*`; any other pattern matches only itself.
/// When several patterns match, the most specific one applies.

import Foundation

enum BundleIdentifierPattern {
    /// The text before a trailing `*`, or nil when `pattern` is a plain bundle identifier.
    static func wildcardPrefix(_ pattern: String) -> Substring? {
        pattern.hasSuffix("*") ? pattern.dropLast() : nil
    }

    static func matches(_ pattern: String, bundleIdentifier: String) -> Bool {
        if let prefix = wildcardPrefix(pattern) {
            return bundleIdentifier.hasPrefix(prefix)
        }
        return pattern == bundleIdentifier
    }
}

/// Values keyed by bundle identifier pattern. A bundle identifier gets the value of the most specific
/// pattern that matches it: the bundle identifier itself, else the longest wildcard pattern.
struct BundleIdentifierPatternMap<Value> {
    private let exactValues: [String: Value]
    /// Wildcard patterns' prefixes with their values, longest prefix first.
    private let wildcardValues: [(prefix: Substring, value: Value)]

    init(_ valuesByPattern: [String: Value]) {
        var exactValues: [String: Value] = [:]
        var wildcardValues: [(prefix: Substring, value: Value)] = []
        for (pattern, value) in valuesByPattern {
            if let prefix = BundleIdentifierPattern.wildcardPrefix(pattern) {
                wildcardValues.append((prefix, value))
            } else {
                exactValues[pattern] = value
            }
        }
        self.exactValues = exactValues
        // Two different prefixes of one length can't both match a bundle identifier, so ties don't matter
        self.wildcardValues = wildcardValues.sorted { $0.prefix.count > $1.prefix.count }
    }

    subscript(bundleIdentifier: String) -> Value? {
        exactValues[bundleIdentifier]
            ?? wildcardValues.first { bundleIdentifier.hasPrefix($0.prefix) }?.value
    }
}
