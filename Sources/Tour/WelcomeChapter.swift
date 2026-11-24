/// The tour's Welcome chapter: Zonogy's permissions, zones, the destination, finding and moving windows, the
/// macOS settings that suit it, and where to go next, the other chapters among them.
import AppKit

extension TourPage {
    static func welcomeChapter() -> [TourPage] {
        let gestureKeys = keys(ModifierCombinationPreferences.mouseGestures.modifiers.displayString)
        let minimize = shortcutKeys(.minimizeActiveWindow)

        return [
            TourPage(title: "Permissions", blocks: [
                .permissions(.all),
                .points([
                    Point(lead: "Accessibility", text: "is required. It lets Zonogy move and resize windows and respond to its shortcuts."),
                    Point(lead: "Screen Recording", text: "is optional. It is used only for the thumbnails of WinShot snapshots."),
                ]),
                .paragraph("Zonogy restarts once Accessibility is granted, and this tour continues."),
            ]),
            TourPage(title: "Zones", scene: "zones", blocks: [
                .paragraph("An empty zone shows a placeholder that holds the space for a window. Click a New Zone Bar at the side of the display to add a zone, and × on an empty zone to remove it."),
                .tryIt("Click a New Zone Bar, then × on the new zone. A bar disappears once no more zones can be added on its side."),
            ]),
            TourPage(title: "The destination zone", scene: "destination", blocks: [
                .paragraph("The next window opens in the destination zone, marked by a glow."),
                .paragraph("When every zone is full, new windows float above the tiles."),
                .tryIt("Minimize a window with \(minimize), then open a new window in any app, such as an email reply."),
            ]),
            TourPage(title: "Any zone as the destination", scene: "replace", blocks: [
                .paragraph("Hold \(gestureKeys) and click a zone to make it the destination, even if a window is in it. The next window replaces that window, which is minimized."),
                .tryIt("Hold \(gestureKeys) and click a window, then open a new window, such as an email reply."),
            ]),
            TourPage(title: "Finding windows", scene: "finding", blocks: [
                .points([
                    Point(lead: "Launcher (\(shortcutKeys(.showLauncher))):", text: "type to find any app or window. \(keys("Tab")) lists an app's windows."),
                    Point(lead: "CmdTab (\(shortcutKeys(.showCmdTab))):", text: "switches between windows, not apps, most recent first."),
                    Point(lead: "Dock:", text: "click an icon for the app's main or most recently used window, or hover to choose among its windows. Hold \(keys("Shift")) for the normal Dock, for example to rearrange icons."),
                ]),
                .tryIt("Hover over a running app's Dock icon."),
            ]),
            TourPage(title: "Moving and resizing", scene: "moving", blocks: [
                .paragraph("Drag a window onto another zone to move it there. A window already there swaps places."),
                .paragraph("To resize zones, hover between two zones and drag the bar that appears. Resizing a window by its own edge lasts only until you switch windows."),
                .paragraph("A window too big for its zone slides fully into view while you use it."),
                .tryIt("Drag a window onto another zone."),
            ]),
            TourPage(title: "Finish setting up", blocks: [
                .paragraph("These settings in System Settings > Desktop & Dock make Zonogy work better."),
                .points([
                    Point(lead: "Minimize windows using:", text: "Scale Effect. Zonogy minimizes often, and Scale is quicker."),
                    Point(lead: "Minimize windows into application icon:", text: "on, so minimized windows do not fill the Dock."),
                    Point(lead: "Drag windows to left or right edge of screen to tile:", text: "off. It interferes with dropping windows on a New Zone Bar."),
                    Point(lead: "Displays have separate Spaces:", text: "on (the macOS default)."),
                    Point(lead: "Stage Manager:", text: "off. Zonogy takes its place."),
                ]),
                .button(title: "Open Desktop & Dock Settings…") { AppLinks.open(AppLinks.desktopAndDockSettings) },
                .paragraph("More suggestions, such as remapping Caps Lock, are in the README."),
                .button(title: "Open Additional Suggestions…") { AppLinks.open(AppLinks.additionalSuggestions) },
            ]),
            TourPage(title: "More to discover", blocks: [
                .points([
                    Point(lead: "Drag a Dock icon, file, or link", text: "onto an empty zone or a New Zone Bar to open it there."),
                ]),
                .paragraph("Every shortcut is in Preferences > Shortcuts, and this tour is under Help in the Zonogy menu."),
            ]),
        ]
    }
}
