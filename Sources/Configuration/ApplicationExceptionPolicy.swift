import Foundation

/// Configuration-driven per-application exception rules.
/// These rules allow specific bundle identifiers to opt out of default
/// filtering behavior (for example, activation policy checks).
struct ApplicationExceptionRule: Codable {
    let bundleIdentifier: String
    let ignoreActivationPolicy: Bool?
    let ignoreZoomButtonRequirement: Bool?
    let ignoreHeightRequirement: Bool?
    let disallowEmptyTitleWindows: Bool?
    let hasMainWindow: Bool?
    let snapToZoneOnSelfResize: Bool?
    /// When enabled, Zonogy preserves the window's current width when applying zone frames.
    let doNotResizeWidth: Bool?
    /// When enabled, Zonogy does not consume this app's Control-Command mouse gestures.
    let disableControlCommandMouseGestures: Bool?
    /// Some apps (e.g., Keynote presentation windows) don't expose `AXFullScreen` reliably.
    /// When enabled, Zonogy treats `AXUnknown` windows that span the full screen width as full-screen.
    let treatAXUnknownFullWidthAsFullScreen: Bool?
    /// When enabled, a window's zoom button must be enabled (not grayed out) for Zonogy to manage it.
    let requireActiveZoomButton: Bool?
    /// Some apps (e.g., Adobe Premiere Pro) report their windows with a non-standard accessibility
    /// role (such as `AXUnknown`) and/or subrole (such as `AXDialog`) instead of the standard
    /// `AXWindow` / `AXStandardWindow`. When enabled, Zonogy relaxes the role and subrole checks so
    /// these windows can still be managed (the other criteria—movable, zoom, height—still apply).
    let manageNonStandardWindows: Bool?
    let excludedWindowTitles: [String]?

    init(
        bundleIdentifier: String,
        ignoreActivationPolicy: Bool? = nil,
        ignoreZoomButtonRequirement: Bool? = nil,
        ignoreHeightRequirement: Bool? = nil,
        disallowEmptyTitleWindows: Bool? = nil,
        hasMainWindow: Bool? = nil,
        snapToZoneOnSelfResize: Bool? = nil,
        doNotResizeWidth: Bool? = nil,
        disableControlCommandMouseGestures: Bool? = nil,
        treatAXUnknownFullWidthAsFullScreen: Bool? = nil,
        requireActiveZoomButton: Bool? = nil,
        manageNonStandardWindows: Bool? = nil,
        excludedWindowTitles: [String]? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.ignoreActivationPolicy = ignoreActivationPolicy
        self.ignoreZoomButtonRequirement = ignoreZoomButtonRequirement
        self.ignoreHeightRequirement = ignoreHeightRequirement
        self.disallowEmptyTitleWindows = disallowEmptyTitleWindows
        self.hasMainWindow = hasMainWindow
        self.snapToZoneOnSelfResize = snapToZoneOnSelfResize
        self.doNotResizeWidth = doNotResizeWidth
        self.disableControlCommandMouseGestures = disableControlCommandMouseGestures
        self.treatAXUnknownFullWidthAsFullScreen = treatAXUnknownFullWidthAsFullScreen
        self.requireActiveZoomButton = requireActiveZoomButton
        self.manageNonStandardWindows = manageNonStandardWindows
        self.excludedWindowTitles = excludedWindowTitles
    }

    /// Returns true when this rule carries any non-default per-app exception.
    var hasMeaningfulExceptionSettings: Bool {
        if ignoreActivationPolicy == true { return true }
        if ignoreZoomButtonRequirement == true { return true }
        if ignoreHeightRequirement == true { return true }
        if disallowEmptyTitleWindows == true { return true }
        if hasMainWindow == true { return true }
        if snapToZoneOnSelfResize == true { return true }
        if doNotResizeWidth == true { return true }
        if disableControlCommandMouseGestures == true { return true }
        if treatAXUnknownFullWidthAsFullScreen == true { return true }
        if requireActiveZoomButton == true { return true }
        if manageNonStandardWindows == true { return true }
        if let excludedWindowTitles, !excludedWindowTitles.isEmpty { return true }
        return false
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
            doNotResizeWidth: override.doNotResizeWidth ?? doNotResizeWidth,
            disableControlCommandMouseGestures: override.disableControlCommandMouseGestures ?? disableControlCommandMouseGestures,
            treatAXUnknownFullWidthAsFullScreen: override.treatAXUnknownFullWidthAsFullScreen ?? treatAXUnknownFullWidthAsFullScreen,
            requireActiveZoomButton: override.requireActiveZoomButton ?? requireActiveZoomButton,
            manageNonStandardWindows: override.manageNonStandardWindows ?? manageNonStandardWindows,
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

    /// Returns true if the app prefers its "main window" (lowest CGWindowID) when multiple windows exist
    func hasMainWindow(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.hasMainWindow ?? false
    }

    /// Returns true if the app wants Zonogy to snap its window back to the zone
    /// immediately after a self-initiated resize (e.g., internal UI panels opening/closing).
    func snapsToZoneOnSelfResize(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.snapToZoneOnSelfResize ?? false
    }

    /// Returns true if Zonogy should preserve the window's current width when
    /// applying zone-aligned frames for this bundle.
    func doesNotResizeWidth(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.doNotResizeWidth ?? false
    }

    /// Returns true if Zonogy should not consume this app's Control-Command click/drag mouse gestures.
    func disablesControlCommandMouseGestures(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.disableControlCommandMouseGestures ?? false
    }

    /// Returns true if windows with empty titles should be ignored for this bundle.
    /// By default, empty-title windows are managed; set this to opt out.
    func disallowsEmptyTitleWindows(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.disallowEmptyTitleWindows ?? false
    }

    /// Returns true if the app opts into the `AXUnknown` full-width full-screen heuristic.
    /// By default, this heuristic is disabled since it can produce false positives during animations.
    func treatsAXUnknownFullWidthAsFullScreen(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.treatAXUnknownFullWidthAsFullScreen ?? false
    }

    /// Returns true if the app requires the zoom button to be enabled (not grayed out)
    /// for Zonogy to manage its windows.
    func requiresActiveZoomButton(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.requireActiveZoomButton ?? false
    }

    /// Returns true if Zonogy should manage this app's windows even when they report a
    /// non-standard accessibility role (e.g., `AXUnknown`) or subrole (e.g., `AXDialog`).
    func managesNonStandardWindows(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rulesByBundleId[bundleIdentifier]?.manageNonStandardWindows ?? false
    }

    /// Returns the list of window titles to exclude from management for this bundle.
    func excludedWindowTitles(forBundleIdentifier bundleIdentifier: String) -> [String] {
        rulesByBundleId[bundleIdentifier]?.excludedWindowTitles ?? []
    }
}
