/// The Welcome tour's pages: what Zonogy is, its permissions, zones, the destination, finding and moving
/// windows, the macOS settings that suit it, and what to look into next.
import AppKit

extension TourPage {
    static func welcomeTour() -> [TourPage] {
        let shortcuts = KeyboardShortcutPreferences.shared
        let gestureKeys = ModifierCombinationPreferences.mouseGestures.modifiers.displayString
        let navigationKeys = ModifierCombinationPreferences.zoneNavigation.modifiers.displayString
        let minimize = shortcuts.keyPhrase(for: .minimizeActiveWindow)

        return [
            TourPage(title: "Welcome to Zonogy", scene: "welcome", blocks: [
                .paragraph("Zonogy keeps your windows in zones: areas of the display that stay put, even when empty. The next window always opens where you expect, and any window is a few keystrokes away."),
                .paragraph("When Zonogy starts, it arranges your open windows into zones and minimizes the ones that do not fit. Nothing is closed."),
                .paragraph("Zonogy replaces Spaces and Stage Manager, so turn Stage Manager off."),
            ]),
            TourPage(title: "Permissions", blocks: [
                .permissions(.all),
                .points([
                    Point(lead: "Accessibility", text: "is required. It lets Zonogy move and resize windows and respond to its shortcuts."),
                    Point(lead: "Screen Recording", text: "is optional. It is used only for the thumbnails of WinShot snapshots."),
                ]),
                .paragraph("Zonogy restarts once Accessibility is granted, and this tour continues."),
            ]),
            TourPage(title: "Zones", scene: "zones", blocks: [
                .paragraph("Your windows now sit in zones. Windows that did not fit were minimized, not closed."),
                .paragraph("An empty zone shows a placeholder that holds the space for a window. Click a New Zone Bar at the side of the display to add a zone, and × on an empty zone to remove it."),
                .tryIt("Click a New Zone Bar, then × on the new zone. A full display shows no bar."),
            ]),
            TourPage(title: "The destination zone", scene: "destination", blocks: [
                .paragraph("One zone at a time is the destination, marked by a glow: the next window opens there."),
                .paragraph("Minimize or close a window and its zone becomes the destination, with the Launcher open in it. Type a few letters of an app or window, then press Return."),
                .paragraph("When every zone is full, no zone is the destination, and new windows float above the tiles. A floating window is minimized when you focus a tiled window it covers."),
                .tryIt("Click a window, minimize it with \(minimize), then pick another in the Launcher."),
            ]),
            TourPage(title: "Finding windows", scene: "finding", blocks: [
                .paragraph("Minimized windows are out of sight but one step away."),
                .points([
                    Point(lead: "Launcher (\(shortcuts.keyPhrase(for: .showLauncher))):", text: "type to find any app or window. Tab lists an app's windows."),
                    Point(lead: "CmdTab (\(shortcuts.keyPhrase(for: .showCmdTab))):", text: "switches between windows, not apps, most recent first."),
                    Point(lead: "Dock:", text: "click an icon for the app's main or most recently used window, or hover to choose among its windows. Hold Shift for the normal Dock, for example to rearrange icons."),
                ]),
                .tryIt("Hover over a running app's Dock icon."),
            ]),
            TourPage(title: "Moving and resizing", scene: "moving", blocks: [
                .paragraph("Drag a window onto another zone to move it there. A window already there swaps places."),
                .paragraph("Drop it on a New Zone Bar to give it a new zone, or on the Floating Zone Bar at the bottom of the display to float it above the tiles."),
                .paragraph("To resize zones, hover between two zones and drag the bar that appears. Dragging a window's own edge is temporary: the window returns to its zone when you switch windows."),
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
            ]),
            TourPage(title: "More to discover", blocks: [
                .paragraph("Gestures and shortcuts worth learning next:"),
                .points([
                    Point(lead: "\(gestureKeys)-click a zone:", text: "make it the destination, even if occupied."),
                    Point(lead: "Hold \(gestureKeys) while dragging a window:", text: "switch it between tiled and floating."),
                    Point(lead: "Drag a Dock icon onto a zone, or a file or link onto an empty one:", text: "open it there. With a Dock icon, hold Option for a new window."),
                    Point(lead: "Hold \(navigationKeys) and press the arrows:", text: "move from zone to zone by keyboard."),
                    Point(lead: "\(minimize) twice:", text: "minimize the window, then remove its zone."),
                    Point(lead: "\(shortcuts.keyPhrase(for: .clearOrResetZones)):", text: "clear the zones on this display."),
                    Point(lead: "\(shortcuts.keyPhrase(for: .saveWinShotSnapshot)) and \(shortcuts.keyPhrase(for: .showWinShotChooser)):", text: "save and switch between window arrangements. Snapshots are off at first: see the WinShot tour below."),
                ]),
                .paragraph("Behavior that may surprise you:"),
                .points([
                    Point(lead: "ActiveFit:", text: "a window that cannot shrink to its zone slides fully into view while you use it, and back when you switch windows."),
                    Point(lead: "Hiding an app:", text: "minimizes its windows instead, so its zones stay."),
                    Point(lead: "Full screen:", text: "pauses Zonogy on that display until the window leaves full screen."),
                ]),
                .paragraph("Every shortcut is listed and settable in Preferences > Shortcuts. Reopen this tour from the Zonogy menu bar icon, under Help."),
                .button(title: "Take the WinShot Tour…") { TourWindowController.shared.show(.winShot) },
            ]),
        ]
    }
}
