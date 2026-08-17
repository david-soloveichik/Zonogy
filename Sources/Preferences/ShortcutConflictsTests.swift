import Carbon
import Foundation

/// Guardrail tests for shortcut conflict detection: which chords count as contested, the order and
/// wording the Preferences marks report them in, which chords an action's binding claims beyond
/// itself, and that the factory defaults have no conflicts — every default binding clear of every
/// other and of Zone Navigation's default chords.
enum ShortcutConflictsTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ShortcutConflictsTests: \(message)")
                allPassed = false
            }
        }

        typealias Action = KeyboardShortcutPreferences.ShortcutAction
        let cmdCtrl = UInt32(cmdKey | controlKey)
        let upArrow = KeyboardShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: cmdCtrl)
        let letterA = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: cmdCtrl)
        let letterM = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: cmdCtrl)
        let equal = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Equal), modifiers: cmdCtrl)
        // Same key as `letterM`, different modifiers: a distinct chord.
        let cmdM = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey))

        // MARK: - Nothing shared: no conflicts

        let clear = ShortcutConflicts(claims: [
            (claimant: .action(.addZone), shortcuts: [equal]),
            (claimant: .action(.minimizeActiveWindow), shortcuts: [cmdM]),
            (claimant: .zoneNavigation, shortcuts: [upArrow, letterA]),
        ])
        assert(clear.isEmpty, "distinct chords should not conflict")
        assert(clear.conflicts(of: .action(.addZone)).isEmpty, "an uncontested claimant should report no conflicts")
        assert(clear.description(for: .zoneNavigation) == nil, "an uncontested claimant should have no description")
        assert(
            ShortcutConflicts(claims: [(claimant: .action(.minimizeActiveWindow), shortcuts: [cmdM]),
                                       (claimant: .action(.minimizeWindowOrRemoveZoneAtCursor), shortcuts: [letterM])]).isEmpty,
            "the same key under different modifiers is a different chord"
        )

        // MARK: - Shared chords: every holder is a party, and each sees the others in claim order

        let contested = ShortcutConflicts(claims: [
            (claimant: .action(.addZone), shortcuts: [upArrow]),
            (claimant: .action(.removeZone), shortcuts: [letterM]),
            (claimant: .action(.showLauncher), shortcuts: [letterA]),
            (claimant: .action(.minimizeWindowOrRemoveZoneAtCursor), shortcuts: [letterM]),
            (claimant: .zoneNavigation, shortcuts: [upArrow, letterA]),
        ])
        assert(!contested.isEmpty, "shared chords should conflict")

        let addZone = contested.conflicts(of: .action(.addZone))
        assert(
            addZone.count == 1 && addZone.first?.shortcut == upArrow && addZone.first?.others == [.zoneNavigation],
            "a shortcut on a Zone Navigation chord should list Zone Navigation as the other holder"
        )
        assert(
            contested.conflicts(of: .action(.removeZone)).first?.others == [.action(.minimizeWindowOrRemoveZoneAtCursor)],
            "two shortcuts on one chord should each list the other"
        )
        assert(
            contested.conflicts(of: .action(.minimizeWindowOrRemoveZoneAtCursor)).first?.others == [.action(.removeZone)],
            "the conflict should be reported from both sides"
        )
        assert(
            contested.conflicts(of: .action(.clearOrResetZones)).isEmpty,
            "a claimant holding nothing contested should report no conflicts"
        )

        // Zone Navigation holds two contested chords; they come back in first-claim order — the
        // order the table listed them, since table claims precede Zone Navigation's.
        let zoneNavigation = contested.conflicts(of: .zoneNavigation)
        assert(
            zoneNavigation.map(\.shortcut) == [upArrow, letterA],
            "a claimant's contested chords should list in first-claim order"
        )
        assert(
            zoneNavigation.map(\.others) == [[.action(.addZone)], [.action(.showLauncher)]],
            "each contested chord should carry its other holders"
        )

        // MARK: - Descriptions: every other holder, each with the contested chord

        assert(
            contested.description(for: .action(.addZone)) == "Also used by Zone Navigation (⌃⌘↑)",
            "a table row names the other holder and the chord"
        )
        assert(
            contested.description(for: .zoneNavigation)
                == "Also used by Add Zone (⌃⌘↑) and Show Launcher (⌃⌘A)",
            "the Zone Navigation card names each holder with the chord it sits on"
        )

        // Three holders of one chord: a natural list, and every holder sees the other two.
        let crowded = ShortcutConflicts(claims: [
            (claimant: .action(.addZone), shortcuts: [upArrow]),
            (claimant: .action(.removeZone), shortcuts: [upArrow]),
            (claimant: .zoneNavigation, shortcuts: [upArrow]),
        ])
        assert(
            crowded.description(for: .action(.removeZone))
                == "Also used by Add Zone (⌃⌘↑) and Zone Navigation (⌃⌘↑)",
            "several other holders should read as a natural list"
        )

        // MARK: - A claimant listing a chord twice doesn't conflict with itself

        assert(
            ShortcutConflicts(claims: [(claimant: .zoneNavigation, shortcuts: [upArrow, upArrow])]).isEmpty,
            "a repeated chord within one claimant is not a conflict"
        )

        // MARK: - Claimed chords: a binding claims itself, and a CmdTab binding without Shift also
        // claims its Shift variant (reverse cycling)

        let cmdUp = KeyboardShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(cmdKey))
        let shiftCmdUp = KeyboardShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(cmdKey | shiftKey))
        assert(Action.addZone.claimedShortcuts(for: cmdUp) == [cmdUp], "an ordinary action claims only its binding")
        assert(
            Action.showCmdTab.claimedShortcuts(for: cmdUp) == [cmdUp, shiftCmdUp],
            "a CmdTab binding without Shift also claims the chord with Shift"
        )
        assert(
            Action.showCmdTabCurrentApp.claimedShortcuts(for: shiftCmdUp) == [shiftCmdUp],
            "a CmdTab binding that already includes Shift claims only itself"
        )
        // The Shift variant is a real conflict: CmdTab's tap engages on it before any hotkey fires.
        let cmdTabAlias = ShortcutConflicts(claims: [
            (claimant: .action(.addZone), shortcuts: [shiftCmdUp]),
            (claimant: .action(.showCmdTab), shortcuts: Action.showCmdTab.claimedShortcuts(for: cmdUp)),
        ])
        assert(
            cmdTabAlias.description(for: .action(.showCmdTab)) == "Also used by Add Zone (⇧⌘↑)",
            "the CmdTab row should name the contested Shift chord, not its own binding"
        )
        assert(
            cmdTabAlias.description(for: .action(.addZone)) == "Also used by CmdTab Window Switcher (⇧⌘↑)",
            "the shortcut on CmdTab's Shift chord should be marked too"
        )

        // MARK: - Factory defaults are conflict-free: every default binding's claimed chords are
        // distinct, and none sits on a chord Zone Navigation holds at its own defaults (all groups,
        // the default keys, Control-Command)

        var defaults: [(claimant: ShortcutClaimant, shortcuts: [KeyboardShortcut])] = Action.allCases.map {
            (claimant: .action($0), shortcuts: $0.claimedShortcuts(for: $0.defaultShortcut))
        }
        defaults.append((
            claimant: .zoneNavigation,
            shortcuts: ZoneNavigationInterceptor.claimedShortcuts(for: .defaultModifiers, keys: .default)
        ))
        let atDefaults = ShortcutConflicts(claims: defaults)
        assert(atDefaults.isEmpty, "the factory defaults should have no conflicts")

        if allPassed {
            print("ShortcutConflictsTests: all tests passed")
        }
        return allPassed
    }
}
