import Foundation

/// Configuration-driven per-application exception rules.
/// These rules allow specific bundle identifiers to opt out of default
/// filtering behavior (for example, activation policy checks).
struct ApplicationExceptionRule: Decodable {
    let bundleIdentifier: String
    let ignoreActivationPolicy: Bool?
    let ignoreZoomButtonRequirement: Bool?
    let ignoreHeightRequirement: Bool?
    let disallowEmptyTitleWindows: Bool?
    let hasMainWindow: Bool?
    let snapToZoneOnSelfResize: Bool?
    let excludedWindowTitles: [String]?

    init(
        bundleIdentifier: String,
        ignoreActivationPolicy: Bool? = nil,
        ignoreZoomButtonRequirement: Bool? = nil,
        ignoreHeightRequirement: Bool? = nil,
        disallowEmptyTitleWindows: Bool? = nil,
        hasMainWindow: Bool? = nil,
        snapToZoneOnSelfResize: Bool? = nil,
        excludedWindowTitles: [String]? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.ignoreActivationPolicy = ignoreActivationPolicy
        self.ignoreZoomButtonRequirement = ignoreZoomButtonRequirement
        self.ignoreHeightRequirement = ignoreHeightRequirement
        self.disallowEmptyTitleWindows = disallowEmptyTitleWindows
        self.hasMainWindow = hasMainWindow
        self.snapToZoneOnSelfResize = snapToZoneOnSelfResize
        self.excludedWindowTitles = excludedWindowTitles
    }

    /// Returns a new rule with this rule's values as defaults, overridden by non-nil values from `override`.
    func merged(with override: ApplicationExceptionRule) -> ApplicationExceptionRule {
        ApplicationExceptionRule(
            bundleIdentifier: bundleIdentifier,
            ignoreActivationPolicy: override.ignoreActivationPolicy ?? ignoreActivationPolicy,
            ignoreZoomButtonRequirement: override.ignoreZoomButtonRequirement ?? ignoreZoomButtonRequirement,
            ignoreHeightRequirement: override.ignoreHeightRequirement ?? ignoreHeightRequirement,
            disallowEmptyTitleWindows: override.disallowEmptyTitleWindows ?? disallowEmptyTitleWindows,
            hasMainWindow: override.hasMainWindow ?? hasMainWindow,
            snapToZoneOnSelfResize: override.snapToZoneOnSelfResize ?? snapToZoneOnSelfResize,
            excludedWindowTitles: override.excludedWindowTitles ?? excludedWindowTitles
        )
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

    /// Returns true if the app wants Zonogy to snap its window back to the zone
    /// immediately after a self-initiated resize (e.g., internal UI panels opening/closing).
    func snapsToZoneOnSelfResize(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.snapToZoneOnSelfResize ?? false
    }

    /// Returns true if windows with empty titles should be ignored for this bundle.
    /// By default, empty-title windows are managed; set this to opt out.
    func disallowsEmptyTitleWindows(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.disallowEmptyTitleWindows ?? false
    }

    /// Returns the list of window titles to exclude from management for this bundle.
    func excludedWindowTitles(forBundleIdentifier bundleIdentifier: String) -> [String] {
        rulesByBundleId[bundleIdentifier]?.excludedWindowTitles ?? []
    }
}
