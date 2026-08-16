import Carbon
import Foundation

/// Guardrail tests for the zone-navigation key policy: the key groups' selection-key maps, the
/// chords the gesture claims (a table shortcut on one conflicts with it), the keys that shadow a
/// borrowed key (Show Launcher, Add Zone, Remove Zone, Minimize Focused Window), and key-group
/// persistence.
enum ZoneNavigationChordPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ZoneNavigationChordPolicyTests: \(message)")
                allPassed = false
            }
        }

        // MARK: - Key groups: the arrows step, the letters jump; each group contributes only its
        // own keys, and both are on by default

        let expectedArrows: [CGKeyCode: ZoneNavigationKey] = [
            CGKeyCode(kVK_UpArrow): .move(.up),
            CGKeyCode(kVK_DownArrow): .move(.down),
            CGKeyCode(kVK_LeftArrow): .move(.left),
            CGKeyCode(kVK_RightArrow): .move(.right),
        ]
        let expectedLetters: [CGKeyCode: ZoneNavigationKey] = [
            CGKeyCode(kVK_ANSI_A): .zone(.topLeft),
            CGKeyCode(kVK_ANSI_S): .zone(.topRight),
            CGKeyCode(kVK_ANSI_D): .zone(.bottomLeft),
            CGKeyCode(kVK_ANSI_F): .zone(.bottomRight),
            CGKeyCode(kVK_ANSI_G): .floatingZone,
            CGKeyCode(kVK_ANSI_J): .display(ordinal: 0),
            CGKeyCode(kVK_ANSI_K): .display(ordinal: 1),
            CGKeyCode(kVK_ANSI_L): .display(ordinal: 2),
        ]
        assert(ZoneNavigationKeyGroups.arrows.selectionKeys == expectedArrows, "the arrow group should map the four arrows to moves")
        assert(ZoneNavigationKeyGroups.letters.selectionKeys == expectedLetters, "the letter group should map A/S/D/F, G, and J/K/L to jumps")
        assert(
            ZoneNavigationKeyGroups.all.selectionKeys == expectedArrows.merging(expectedLetters) { arrow, _ in arrow },
            "all groups should contribute every selection key"
        )
        assert(ZoneNavigationKeyGroups().selectionKeys.isEmpty, "no group should contribute no selection keys")
        assert(ZoneNavigationKeyGroups.all == [.arrows, .letters], "the default should enable both groups")

        // Cells carry their column side and stack row; only the arrows step (so only jump keys'
        // auto-repeats are ignored).
        assert(ZoneNavigationCell.topLeft.side == .left && !ZoneNavigationCell.topLeft.isBottom, "top-left is the left column's top")
        assert(ZoneNavigationCell.bottomRight.side == .right && ZoneNavigationCell.bottomRight.isBottom, "bottom-right is the right column's bottom")
        assert(!ZoneNavigationKey.move(.up).isJump, "an arrow steps rather than jumps")
        for key in expectedLetters.values {
            assert(key.isJump, "\(key) should be a jump")
        }

        // MARK: - Claimed chords: the enabled selection keys plus Return, under the given
        // modifiers; nothing when no group is enabled

        let allClaimed = ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], groups: .all)
        assert(allClaimed.count == 13, "all groups should claim the twelve selection keys plus Return")
        assert(
            Set(allClaimed.map(\.keyCode)).isSuperset(of: Set([kVK_UpArrow, kVK_ANSI_A, kVK_ANSI_L, kVK_Return].map(UInt32.init))),
            "all groups should claim the arrows, the letters, and Return"
        )
        assert(
            allClaimed.allSatisfy { $0.modifiers == UInt32(controlKey | cmdKey) },
            "claimed chords should carry the gesture's modifiers"
        )

        let arrowsClaimed = ZoneNavigationInterceptor.claimedShortcuts(for: [.option, .shift], groups: .arrows)
        assert(arrowsClaimed.count == 5, "the arrow group alone should claim the arrows and Return")
        assert(
            !arrowsClaimed.contains { $0.keyCode == UInt32(kVK_ANSI_A) },
            "a disabled letter group should not claim its letters"
        )
        assert(
            arrowsClaimed.allSatisfy { $0.modifiers == UInt32(optionKey | shiftKey) },
            "claimed chords should follow the configured modifiers"
        )
        assert(
            ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], groups: .letters).count == 9,
            "the letter group alone should claim the eight letters and Return"
        )
        assert(
            ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], groups: []).isEmpty,
            "with no group enabled the gesture never engages, so nothing is claimed"
        )

        // MARK: - Borrowed-key shadowing: in-gesture keys act first, then earlier-borrowed keys;
        // ordinary keys don't shadow

        for keyCode in [kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Return, kVK_Escape] {
            assert(
                ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(keyCode), groups: .arrows),
                "key code \(keyCode) has an in-gesture meaning and should shadow a borrowed key"
            )
        }
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(kVK_ANSI_A), groups: .letters),
            "A should shadow a borrowed key when the letters are on"
        )
        assert(
            !ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(kVK_ANSI_A), groups: .arrows),
            "A should not shadow a borrowed key when the letters are off"
        )
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(kVK_Return), groups: []),
            "Return shadows a borrowed key regardless of the groups"
        )
        for keyCode in [kVK_Space, kVK_F5, kVK_Tab] {
            assert(
                !ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(keyCode), groups: .all),
                "key code \(keyCode) should not shadow a borrowed key"
            )
        }
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(
                CGKeyCode(kVK_ANSI_Equal), groups: .arrows,
                earlierBorrowedKeys: [CGKeyCode(kVK_Space), CGKeyCode(kVK_ANSI_Equal)]
            ),
            "a key borrowed earlier in the claim order should shadow a later borrowed key"
        )
        assert(
            !ZoneNavigationInterceptor.shadowsBorrowedKey(
                CGKeyCode(kVK_ANSI_Minus), groups: .arrows,
                earlierBorrowedKeys: [CGKeyCode(kVK_Space), CGKeyCode(kVK_ANSI_Equal)]
            ),
            "distinct earlier-borrowed keys should not shadow an unrelated borrowed key"
        )

        // The default borrowed keys — Space, =, -, M, in claim order — must stay reachable out
        // of the box: no selection key may be one of them, and no default may shadow a later one.
        // (The claim order itself is hand-maintained, in the interceptor's dispatch and the
        // walkthrough's line order.)
        let defaultBorrowedKeys = [
            CGKeyCode(kVK_Space), CGKeyCode(kVK_ANSI_Equal), CGKeyCode(kVK_ANSI_Minus), CGKeyCode(kVK_ANSI_M),
        ]
        for (claimIndex, keyCode) in defaultBorrowedKeys.enumerated() {
            assert(
                !ZoneNavigationInterceptor.shadowsBorrowedKey(
                    keyCode, groups: .all,
                    earlierBorrowedKeys: Array(defaultBorrowedKeys.prefix(claimIndex))
                ),
                "default borrowed key \(keyCode) should stay reachable with every group on"
            )
        }

        // MARK: - Key-group persistence: default when unset, round-trip, unknown bits dropped

        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.zoneNavigationKeyGroups
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        assert(ZoneNavigationKeyPreferences.load() == .all, "load should return both groups when unset")
        defaults.set(ZoneNavigationKeyGroups.arrows.rawValue, forKey: key)
        assert(ZoneNavigationKeyPreferences.load() == .arrows, "a saved group choice should round-trip")
        defaults.set(0, forKey: key)
        assert(ZoneNavigationKeyPreferences.load() == [], "both groups off is a valid saved choice")
        defaults.set(ZoneNavigationKeyGroups.letters.rawValue | (1 << 7), forKey: key)
        assert(ZoneNavigationKeyPreferences.load() == .letters, "unknown bits in a persisted value should be dropped")

        if allPassed {
            print("ZoneNavigationChordPolicyTests: all tests passed")
        }
        return allPassed
    }
}
