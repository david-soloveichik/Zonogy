import Foundation

/// Configuration-driven per-application exception rules.
/// These rules allow specific bundle identifiers to opt out of default
/// filtering behavior (for example, activation policy checks).
struct ApplicationExceptionRule: Decodable {
    let bundleIdentifier: String
    let ignoreActivationPolicy: Bool?
    let ignoreZoomButtonRequirement: Bool?
    let ignoreHeightRequirement: Bool?
    let hasMainWindow: Bool?

    init(
        bundleIdentifier: String,
        ignoreActivationPolicy: Bool? = nil,
        ignoreZoomButtonRequirement: Bool? = nil,
        ignoreHeightRequirement: Bool? = nil,
        hasMainWindow: Bool? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.ignoreActivationPolicy = ignoreActivationPolicy
        self.ignoreZoomButtonRequirement = ignoreZoomButtonRequirement
        self.ignoreHeightRequirement = ignoreHeightRequirement
        self.hasMainWindow = hasMainWindow
    }
}

/// Aggregated lookup helper for application exception rules.
/// Keeps the rest of the system decoupled from the underlying config shape.
struct ApplicationExceptionPolicy {
    private let rulesByBundleId: [String: ApplicationExceptionRule]

    init(rules: [ApplicationExceptionRule] = []) {
        var mapping: [String: ApplicationExceptionRule] = [:]
        for rule in rules {
            mapping[rule.bundleIdentifier] = rule
        }
        self.rulesByBundleId = mapping
    }

    static let empty = ApplicationExceptionPolicy()

    func rule(forBundleIdentifier bundleIdentifier: String) -> ApplicationExceptionRule? {
        rulesByBundleId[bundleIdentifier]
    }

    func ignoresActivationPolicy(forBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let rule = rulesByBundleId[bundleIdentifier] else {
            return false
        }
        return rule.ignoreActivationPolicy ?? false
    }

    func ignoresZoomButtonRequirement(forBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let rule = rulesByBundleId[bundleIdentifier] else {
            return false
        }
        return rule.ignoreZoomButtonRequirement ?? false
    }

    func ignoresHeightRequirement(forBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let rule = rulesByBundleId[bundleIdentifier] else {
            return false
        }
        return rule.ignoreHeightRequirement ?? false
    }

    /// Returns true if the app prefers its "main window" (lowest Zonogy ID) when multiple windows exist
    func hasMainWindow(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.hasMainWindow ?? false
    }
}
