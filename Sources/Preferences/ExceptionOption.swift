/// The on/off per-app exceptions Preferences > Exceptions offers, in edit-sheet order: each one's
/// checkbox title and tooltip, and the short name that stands for it in the table's Exceptions column.

import Foundation

struct ExceptionOption {
    let title: String
    let shortName: String
    let tooltip: String
    let setting: WritableKeyPath<ApplicationExceptionRule, Bool?>

    /// Short names of the two exceptions that aren't on/off rule settings
    static let ignoredShortName = "ignored"
    static let excludedTitlesShortName = "excl"

    static let all: [ExceptionOption] = [
        ExceptionOption(
            title: "Prefer app's main window",
            shortName: "preferMain",
            tooltip: "For Launcher and DockMenus, treat the window with the lowest CGWindowID as this app's main window and prefer it when choosing a window. The Launcher prefers it only while it isn't already in a zone.",
            setting: \.hasMainWindow
        ),
        ExceptionOption(
            title: "Snap to zone on self-resize",
            shortName: "snap",
            tooltip: "Immediately snap window back when the app resizes it internally",
            setting: \.snapToZoneOnSelfResize
        ),
        ExceptionOption(
            title: "Don't resize width",
            shortName: "keepWidth",
            tooltip: "Preserve the window's current width when Zonogy moves it into a zone; only the position and height are adjusted",
            setting: \.doNotResizeWidth
        ),
        ExceptionOption(
            title: "Disable mouse gestures",
            shortName: "noMouseGestures",
            tooltip: "Let this app receive the gesture-modifier clicks and drags instead of Zonogy's mouse-gesture overrides",
            setting: \.disableMouseGestures
        ),
        ExceptionOption(
            title: "Disallow empty title windows",
            shortName: "noEmpty",
            tooltip: "Don't manage windows with empty titles from this app",
            setting: \.disallowEmptyTitleWindows
        ),
        ExceptionOption(
            title: "Ignore activation policy",
            shortName: "activation",
            tooltip: "Manage windows from helper/accessory apps that aren't .regular activation policy",
            setting: \.ignoreActivationPolicy
        ),
        ExceptionOption(
            title: "Ignore zoom button requirement",
            shortName: "zoom",
            tooltip: "Manage windows that don't have a zoom button",
            setting: \.ignoreZoomButtonRequirement
        ),
        ExceptionOption(
            title: "Require active zoom button",
            shortName: "activeZoom",
            tooltip: "Only manage windows whose zoom button is enabled (not grayed out)",
            setting: \.requireActiveZoomButton
        ),
        ExceptionOption(
            title: "Ignore height requirement",
            shortName: "height",
            tooltip: "Manage windows shorter than 250px",
            setting: \.ignoreHeightRequirement
        ),
        ExceptionOption(
            title: "Manage non-standard windows",
            shortName: "nonStd",
            tooltip: "Manage windows even if they report a non-standard accessibility role or subrole (e.g., AXUnknown / AXDialog, as some Adobe apps do)",
            setting: \.manageNonStandardWindows
        ),
        ExceptionOption(
            title: "Treat AXUnknown full-width windows as full-screen",
            shortName: "axUnknownFS",
            tooltip: "Only enable for apps where AXFullScreen is missing/unreliable (e.g., some presentation windows)",
            setting: \.treatAXUnknownFullWidthAsFullScreen
        ),
    ]
}
