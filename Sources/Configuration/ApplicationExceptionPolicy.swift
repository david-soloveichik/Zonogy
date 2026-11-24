import Foundation

/// Configuration-driven per-application exception rules.
/// These rules allow specific bundle identifiers to opt out of default
/// filtering behavior (for example, activation policy checks).
struct ApplicationExceptionRule: Codable, Equatable {
    /// A bundle identifier pattern (see `BundleIdentifierPattern`)
    var bundleIdentifier: String
    var ignoreActivationPolicy: Bool?
    var ignoreZoomButtonRequirement: Bool?
    var ignoreHeightRequirement: Bool?
    var disallowEmptyTitleWindows: Bool?
    var hasMainWindow: Bool?
    var snapToZoneOnSelfResize: Bool?
    /// When enabled, Zonogy preserves the window's current width when applying zone frames.
    var doNotResizeWidth: Bool?
    /// When enabled, Zonogy does not consume this app's mouse gestures (gesture-modifier click/drag).
    var disableMouseGestures: Bool?
    /// Some apps (e.g., Keynote presentation windows) don't expose `AXFullScreen` reliably.
    /// When enabled, Zonogy treats `AXUnknown` windows that span the full screen width as full-screen.
    var treatAXUnknownFullWidthAsFullScreen: Bool?
    /// When enabled, a window's zoom button must be enabled (not grayed out) for Zonogy to manage it.
    var requireActiveZoomButton: Bool?
    /// Some apps (e.g., Adobe Premiere Pro) report their windows with a non-standard accessibility
    /// role (such as `AXUnknown`) and/or subrole (such as `AXDialog`) instead of the standard
    /// `AXWindow` / `AXStandardWindow`. When enabled, Zonogy relaxes the role and subrole checks so
    /// these windows can still be managed (the other criteria—movable, zoom, height—still apply).
    var manageNonStandardWindows: Bool?
    var excludedWindowTitles: [String]?

    init(
        bundleIdentifier: String,
        ignoreActivationPolicy: Bool? = nil,
        ignoreZoomButtonRequirement: Bool? = nil,
        ignoreHeightRequirement: Bool? = nil,
        disallowEmptyTitleWindows: Bool? = nil,
        hasMainWindow: Bool? = nil,
        snapToZoneOnSelfResize: Bool? = nil,
        doNotResizeWidth: Bool? = nil,
        disableMouseGestures: Bool? = nil,
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
        self.disableMouseGestures = disableMouseGestures
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
        if disableMouseGestures == true { return true }
        if treatAXUnknownFullWidthAsFullScreen == true { return true }
        if requireActiveZoomButton == true { return true }
        if manageNonStandardWindows == true { return true }
        if let excludedWindowTitles, !excludedWindowTitles.isEmpty { return true }
        return false
    }
}

/// Aggregated lookup helper for Preferences → Exceptions: which apps are ignored, and each app's
/// exception rule. Keeps the rest of the system decoupled from the underlying config shape.
/// Entries are keyed by bundle identifier pattern, and an app follows only the most specific entry
/// that matches it (see `BundleIdentifierPatternMap`), so an exact entry can exempt one app from a pattern.
struct ApplicationExceptionPolicy {
    private struct Entry {
        var isIgnored = false
        var rule: ApplicationExceptionRule?
    }

    private let entries: BundleIdentifierPatternMap<Entry>

    /// For a bundle identifier with several rules, the last one wins.
    init(rules: [ApplicationExceptionRule] = [], ignoredBundleIdentifiers: [String] = []) {
        var entriesByPattern: [String: Entry] = [:]
        for rule in rules {
            entriesByPattern[rule.bundleIdentifier, default: Entry()].rule = rule
        }
        for bundleIdentifier in ignoredBundleIdentifiers {
            entriesByPattern[bundleIdentifier, default: Entry()].isIgnored = true
        }
        self.entries = BundleIdentifierPatternMap(entriesByPattern)
    }

    static let empty = ApplicationExceptionPolicy()

    private func rule(forBundleIdentifier bundleIdentifier: String) -> ApplicationExceptionRule? {
        entries[bundleIdentifier]?.rule
    }

    /// Returns true if Zonogy should never capture or manage this app's windows.
    func ignoresApplication(forBundleIdentifier bundleIdentifier: String) -> Bool {
        entries[bundleIdentifier]?.isIgnored ?? false
    }

    func ignoresActivationPolicy(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.ignoreActivationPolicy ?? false
    }

    func ignoresZoomButtonRequirement(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.ignoreZoomButtonRequirement ?? false
    }

    func ignoresHeightRequirement(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.ignoreHeightRequirement ?? false
    }

    /// Returns true if the app prefers its "main window" (lowest CGWindowID) when multiple windows exist
    func hasMainWindow(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.hasMainWindow ?? false
    }

    /// Returns true if the app wants Zonogy to snap its window back to the zone
    /// immediately after a self-initiated resize (e.g., internal UI panels opening/closing).
    func snapsToZoneOnSelfResize(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.snapToZoneOnSelfResize ?? false
    }

    /// Returns true if Zonogy should preserve the window's current width when
    /// applying zone-aligned frames for this bundle.
    func doesNotResizeWidth(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.doNotResizeWidth ?? false
    }

    /// Returns true if Zonogy should not consume this app's gesture-modifier click/drag mouse gestures.
    func disablesMouseGestures(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.disableMouseGestures ?? false
    }

    /// Returns true if windows with empty titles should be ignored for this bundle.
    /// By default, empty-title windows are managed; set this to opt out.
    func disallowsEmptyTitleWindows(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.disallowEmptyTitleWindows ?? false
    }

    /// Returns true if the app opts into the `AXUnknown` full-width full-screen heuristic.
    /// By default, this heuristic is disabled since it can produce false positives during animations.
    func treatsAXUnknownFullWidthAsFullScreen(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.treatAXUnknownFullWidthAsFullScreen ?? false
    }

    /// Returns true if the app requires the zoom button to be enabled (not grayed out)
    /// for Zonogy to manage its windows.
    func requiresActiveZoomButton(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.requireActiveZoomButton ?? false
    }

    /// Returns true if Zonogy should manage this app's windows even when they report a
    /// non-standard accessibility role (e.g., `AXUnknown`) or subrole (e.g., `AXDialog`).
    func managesNonStandardWindows(forBundleIdentifier bundleIdentifier: String) -> Bool {
        rule(forBundleIdentifier: bundleIdentifier)?.manageNonStandardWindows ?? false
    }

    /// Returns the list of window titles to exclude from management for this bundle.
    func excludedWindowTitles(forBundleIdentifier bundleIdentifier: String) -> [String] {
        rule(forBundleIdentifier: bundleIdentifier)?.excludedWindowTitles ?? []
    }
}
