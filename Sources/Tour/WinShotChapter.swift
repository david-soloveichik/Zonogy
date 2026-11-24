/// The tour's WinShot Snapshots chapter: what a snapshot is, how snapshots are saved, and the chooser that
/// switches between them.
import AppKit

extension TourPage {
    static func winShotChapter() -> [TourPage] {
        let shortcuts = KeyboardShortcutPreferences.shared
        let save = shortcuts.keyPhrase(for: .saveWinShotSnapshot)
        // The chooser is worked like Command-Tab: its shortcut's modifiers are held while its key is tapped.
        let chooser = shortcuts.shortcut(for: .showWinShotChooser).map { shortcut in
            (hold: String(shortcut.displayString.dropLast(shortcut.keyDisplayString.count)), tap: shortcut.keyDisplayString)
        }
        let openChooser = chooser.map { "Hold \($0.hold) and tap \($0.tap)" }
            ?? "Use \(shortcuts.keyPhrase(for: .showWinShotChooser))"

        return [
            TourPage(title: "WinShot snapshots", scene: "winshot-switching", blocks: [
                .paragraph("A snapshot records which windows are in which zones on a display. Switching to it brings the whole arrangement back: the zones, and the windows in them."),
                .paragraph("The same window can be part of several snapshots."),
                .toggle(
                    title: "Enable WinShot",
                    isOn: { WinShotPreferencesStore.loadEnabled() },
                    set: { AppController.shared.setWinShotEnabledFromSettings($0) }),
            ]),
            TourPage(title: "Saving snapshots", blocks: [
                .paragraph("Save the arrangement on the active display with \(save), or with Save Snapshot in the Zonogy menu."),
                .paragraph("Zonogy can also save automatically (Preferences > Snapshots):"),
                .points([
                    Point(lead: "Before Clear/Reset Zones or restoring a snapshot:", text: "saves the arrangement you are about to lose."),
                    Point(lead: "After every change:", text: "saves each arrangement once it has lasted a few seconds."),
                ]),
                .permissions(.screenRecording),
                .paragraph("Without Screen Recording, thumbnails show gray blocks."),
                .tryIt("With WinShot on, press \(save) to save this arrangement."),
            ]),
            TourPage(title: "Switching snapshots", scene: "winshot-display", blocks: [
                .paragraph("\(openChooser) to open the chooser on the active display, and tap again to step through its snapshots, most recent first. Add Shift to step back. Release to restore the selected snapshot; Escape cancels."),
                .points([
                    Point(lead: "Click a thumbnail", text: "to restore it at once, or its × to delete it."),
                    Point(lead: "Drag a thumbnail to another display", text: "to open the arrangement there."),
                ]),
                .tryIt("Save two arrangements, then \(chooser.map { "hold \($0.hold), tap \($0.tap) twice" } ?? "open the chooser"), and release."),
            ]),
        ]
    }
}
