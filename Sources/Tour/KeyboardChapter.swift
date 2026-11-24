/// The tour's Keyboard chapter: the everyday shortcuts (adding and removing zones, keeping one zone, clearing
/// the display), then zone navigation: stepping between zones with the arrow keys, and acting on the zone the
/// circle is on.
import AppKit

extension TourPage {
    static func keyboardChapter() -> [TourPage] {
        let shortcuts = KeyboardShortcutPreferences.shared
        let addZone = shortcutKeys(.addZone)
        let minimize = shortcutKeys(.minimizeActiveWindow)
        let oneZone = shortcutKeys(.collapseToOneZone)
        let clear = shortcutKeys(.clearOrResetZones)
        let hold = keys(ModifierCombinationPreferences.zoneNavigation.modifiers.displayString)
        // An action inside the gesture borrows the key of its shortcut.
        func key(_ action: KeyboardShortcutPreferences.ShortcutAction) -> String {
            shortcuts.shortcut(for: action).map { keys($0.keyDisplayString) } ?? "the \(action.displayName) key"
        }
        let move = key(.moveFocusedWindowToTargetZone)

        return [
            TourPage(title: "Adding and removing zones", scene: "keyboard-zones", blocks: [
                .paragraph("Press \(addZone) to add a zone. It opens empty, with the Launcher in it."),
                .paragraph("Press \(minimize) to minimize the focused window. Its zone stays, with the Launcher open; press \(minimize) again to remove the zone. The same goes for \(keys("⌘W")), which closes the window."),
                .tryIt("Press \(addZone), pick a window in the Launcher, then press \(minimize) twice."),
            ]),
            TourPage(title: "One zone", scene: "keyboard-one-zone", blocks: [
                .paragraph("Press \(oneZone) to keep only the focused window's zone. The window fills the display, and the other windows are minimized."),
                .tryIt("Click a window, then press \(oneZone)."),
            ]),
            TourPage(title: "Clearing the display", scene: "keyboard-clear", blocks: [
                .paragraph("Press \(clear) to clear the display: every window on it is minimized, and its zones stay. Press it again to go back to one zone."),
                .tryIt("Press \(clear) twice, then pick a window in the Launcher."),
            ]),
            TourPage(title: "Stepping between zones", scene: "keyboard-stepping", blocks: [
                .paragraph("Hold \(hold) and press an arrow key. A circle marks a zone, and each arrow steps it to the next zone in that direction."),
                .paragraph("Jump keys take the circle straight to a zone or display (Preferences > Shortcuts)."),
                .paragraph("Release \(hold) to focus this zone's window, or to make this zone the destination if it is empty."),
                .tryIt("Hold \(hold), press an arrow or two, then release."),
            ]),
            TourPage(title: "Acting on this zone", scene: "keyboard-acting", blocks: [
                .paragraph("While still holding \(hold), these keys act on the circle's zone (\(keys("esc")) cancels):"),
                .points([
                    Point(lead: move, text: "moves the focused window into this zone."),
                    Point(lead: key(.showLauncher), text: "makes this zone the destination and opens the Launcher."),
                    Point(lead: "\(key(.addZone)), \(key(.removeZone)), \(key(.minimizeActiveWindow))", text: "add a zone, remove this zone, and minimize its window."),
                ]),
                .tryIt("Hold \(hold), step to another zone, and press \(move)."),
            ]),
        ]
    }
}
