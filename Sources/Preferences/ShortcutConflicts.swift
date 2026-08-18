/// Keyboard shortcut conflicts: two or more claimants holding the same chord.
///
/// A claimant is anything that listens for chords system-wide — each action in the shortcut
/// table, and Zone Navigation, which holds its navigation keys under its modifiers.
/// The check runs over plain claims (a claimant and the chords it holds), so a claimant may hold
/// any number of chords — an action's binding can claim more than itself (see
/// `ShortcutAction.claimedShortcuts`) — and a new claimant, or user-chosen navigation keys, plugs
/// in without touching it. Conflicts are allowed to stand and are shown in Preferences ▸ Shortcuts
/// rather than prevented: only one party can respond to a contested chord (an event tap that
/// engages acts before any hotkey; between two hotkeys, the first registered), so every party is
/// marked and the user changes either.
import Foundation

/// Something that listens for keyboard chords.
enum ShortcutClaimant: Hashable {
    case action(KeyboardShortcutPreferences.ShortcutAction)
    case zoneNavigation

    var displayName: String {
        switch self {
        case .action(let action): return action.displayName
        case .zoneNavigation: return "Zone Navigation"
        }
    }
}

struct ShortcutConflicts {
    /// The contested chords in first-claim order, each with every claimant holding it (two or
    /// more, in claim order).
    private let contested: [(shortcut: KeyboardShortcut, claimants: [ShortcutClaimant])]

    init(claims: [(claimant: ShortcutClaimant, shortcuts: [KeyboardShortcut])]) {
        var claimants: [KeyboardShortcut: [ShortcutClaimant]] = [:]
        var order: [KeyboardShortcut] = []
        for claim in claims {
            for shortcut in claim.shortcuts {
                var holders = claimants[shortcut] ?? []
                if holders.isEmpty { order.append(shortcut) }
                // A claimant listing one chord twice doesn't conflict with itself.
                if !holders.contains(claim.claimant) { holders.append(claim.claimant) }
                claimants[shortcut] = holders
            }
        }
        contested = order.compactMap { shortcut in
            guard let holders = claimants[shortcut], holders.count > 1 else { return nil }
            return (shortcut, holders)
        }
    }

    var isEmpty: Bool { contested.isEmpty }

    /// Each contested chord `claimant` holds, with the other claimants on it, in first-claim order.
    func conflicts(of claimant: ShortcutClaimant) -> [(shortcut: KeyboardShortcut, others: [ShortcutClaimant])] {
        contested.compactMap { entry in
            guard entry.claimants.contains(claimant) else { return nil }
            return (entry.shortcut, entry.claimants.filter { $0 != claimant })
        }
    }

    /// Who else holds `claimant`'s chords, each with the chord — "Also used by Add Zone (⌃⌘↑) and
    /// Zone Navigation (⌃⌘A)" — or nil when none is contested. The chord is always named: a holder
    /// of several chords (Zone Navigation, or a CmdTab binding with its Shift variant) may be
    /// contested on one that isn't the binding on show beside the mark.
    func description(for claimant: ShortcutClaimant) -> String? {
        let names = conflicts(of: claimant).flatMap { conflict in
            conflict.others.map { "\($0.displayName) (\(conflict.shortcut.displayString))" }
        }
        return names.isEmpty ? nil : "Also used by " + names.naturalList
    }
}

extension ShortcutConflicts {
    /// The conflicts among everything configured: the table's shortcuts and the chords Zone
    /// Navigation holds — as saved, or, for the Zone Navigation editor's live check, under proposed
    /// modifiers and keys. The table claims first, so a chord contested with Zone Navigation lists
    /// in table order.
    static func current(
        zoneNavigationModifiers: ModifierCombination = ModifierCombinationPreferences.zoneNavigation.modifiers,
        zoneNavigationKeys: ZoneNavigationKeys = ZoneNavigationKeyPreferences.shared.keys
    ) -> ShortcutConflicts {
        let preferences = KeyboardShortcutPreferences.shared
        var claims: [(claimant: ShortcutClaimant, shortcuts: [KeyboardShortcut])] = []
        for action in KeyboardShortcutPreferences.ShortcutAction.allCases {
            if let shortcut = preferences.shortcut(for: action) {
                claims.append((claimant: .action(action), shortcuts: action.claimedShortcuts(for: shortcut)))
            }
        }
        claims.append((
            claimant: .zoneNavigation,
            shortcuts: ZoneNavigationInterceptor.claimedShortcuts(
                for: zoneNavigationModifiers, keys: zoneNavigationKeys)
        ))
        return ShortcutConflicts(claims: claims)
    }
}
