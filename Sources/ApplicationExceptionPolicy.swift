import Foundation

/// Configuration-driven per-application exception rules.
/// These rules allow specific bundle identifiers to opt out of default
/// filtering behavior (for example, activation policy checks).
struct ApplicationExceptionRule: Decodable {
    let bundleIdentifier: String
    let ignoreActivationPolicy: Bool?

    init(bundleIdentifier: String, ignoreActivationPolicy: Bool? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.ignoreActivationPolicy = ignoreActivationPolicy
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
}

