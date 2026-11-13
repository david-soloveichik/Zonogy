/// The tour's Keyboard chapter: the everyday shortcuts (adding and removing zones, keeping one zone, clearing
/// the display), then zone navigation: stepping between zones with the arrow keys, acting on the zone the
/// circle is on, and the jump keys.
import AppKit

extension TourPage {
    static func keyboardChapter() -> [TourPage] {
        let shortcuts = KeyboardShortcutPreferences.shared
        let addZone = shortcuts.keyPhrase(for: .addZone)
        let minimize = shortcuts.keyPhrase(for: .minimizeActiveWindow)
        let oneZone = shortcuts.keyPhrase(for: .collapseToOneZone)
        let clear = shortcuts.keyPhrase(for: .clearOrResetZones)
        let hold = ModifierCombinationPreferences.zoneNavigation.modifiers.displayString
        // An action inside the gesture borrows the key of its shortcut.
        func key(_ action: KeyboardShortcutPreferences.ShortcutAction) -> String {
            shortcuts.shortcut(for: action)?.keyDisplayString ?? "the \(action.displayName) key"
        }
        let move = key(.moveFocusedWindowToTargetZone)
        let topRightJump = jumpKeyLabel(.zone(.topRight))

        return [
            TourPage(title: "Adding and removing zones", scene: "keyboard-zones", blocks: [
                .paragraph("Press \(addZone) to add a zone. It opens empty, with the Launcher in it."),
                .paragraph("Press \(minimize) to minimize the focused window, as usual. Its zone stays, with the Launcher open; press \(minimize) again to remove the zone. The same goes for ⌘W, which closes the window."),
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
                .paragraph("Release \(hold) to focus this zone's window, or to make this zone the destination if it is empty."),
                .tryIt("Hold \(hold), press an arrow or two, then release."),
            ]),
            TourPage(title: "Acting on this zone", scene: "keyboard-acting", blocks: [
                .paragraph("While still holding \(hold), these keys act on the circle's zone (esc cancels):"),
                .points([
                    Point(lead: move, text: "moves the focused window into this zone, swapping if it is occupied."),
                    Point(lead: key(.showLauncher), text: "makes this zone the destination and opens the Launcher."),
                    Point(lead: "\(key(.addZone)), \(key(.removeZone)), \(key(.minimizeActiveWindow))", text: "add a zone, remove this zone, and minimize its window."),
                ]),
                .tryIt("Hold \(hold), step to another zone, and press \(move)."),
            ]),
            TourPage(title: "Jump keys", blocks: [
                .paragraph("Jump keys take the circle straight to a zone or a display, with no stepping."),
                .illustration(makeJumpKeysIllustration),
                .paragraph("Change these keys, or the keys to hold, in Preferences > Shortcuts > Zone Navigation."),
                .tryIt("Hold \(hold) and press \(topRightJump), then release."),
            ]),
        ]
    }

    private static func jumpKeyLabel(_ jump: ZoneNavigationKey) -> String {
        KeyboardShortcut.keyLabel(forKeyCode: UInt32(ZoneNavigationKeyPreferences.shared.keys[jump])) ?? "?"
    }

    /// The Zone Navigation editor's pictograms of where each jump key lands, with the current keys.
    private static func makeJumpKeysIllustration() -> NSView {
        let zones = ZoneJumpKeysDiagramView()
        let displays = DisplayJumpKeysDiagramView()
        for (jump, cap) in zones.caps.merging(displays.caps, uniquingKeysWith: { first, _ in first }) {
            cap.label = jumpKeyLabel(jump)
        }
        return KeyGroupIllustrationView(
            items: [(zones, ZoneJumpKeysDiagramView.caption), (displays, DisplayJumpKeysDiagramView.caption)],
            columnWidth: 200,
            bandHeight: max(zones.intrinsicContentSize.height, displays.intrinsicContentSize.height))
    }
}
