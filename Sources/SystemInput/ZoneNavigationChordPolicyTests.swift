import Carbon
import Foundation

/// Guardrail tests for the zone-navigation key policy: the selection keys the groups contribute
/// (fixed arrows, configurable jump keys), which settable keys are valid, the chords the gesture
/// claims (a table shortcut on one conflicts with it), the keys that shadow a borrowed key (Show
/// Launcher, Add Zone, Remove Zone, Minimize Focused Window), and persistence.
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

        let a = CGKeyCode(kVK_ANSI_A), s = CGKeyCode(kVK_ANSI_S), l = CGKeyCode(kVK_ANSI_L)
        let one = CGKeyCode(kVK_ANSI_1), space = CGKeyCode(kVK_Space), returnKey = CGKeyCode(kVK_Return)
        let up = CGKeyCode(kVK_UpArrow), escape = CGKeyCode(kVK_Escape)

        // MARK: - Key groups: the arrows step, the jump keys jump; each group contributes only its
        // own keys, and both are on by default

        let expectedArrows: [CGKeyCode: ZoneNavigationKey] = [
            up: .move(.up),
            CGKeyCode(kVK_DownArrow): .move(.down),
            CGKeyCode(kVK_LeftArrow): .move(.left),
            CGKeyCode(kVK_RightArrow): .move(.right),
        ]
        let expectedJumps: [CGKeyCode: ZoneNavigationKey] = [
            a: .zone(.topLeft),
            s: .zone(.topRight),
            CGKeyCode(kVK_ANSI_D): .zone(.bottomLeft),
            CGKeyCode(kVK_ANSI_F): .zone(.bottomRight),
            CGKeyCode(kVK_ANSI_G): .floatingZone,
            CGKeyCode(kVK_ANSI_J): .display(ordinal: 0),
            CGKeyCode(kVK_ANSI_K): .display(ordinal: 1),
            l: .display(ordinal: 2),
        ]
        var arrowsOnly = ZoneNavigationKeys.default
        arrowsOnly.groups = .arrows
        var jumpsOnly = ZoneNavigationKeys.default
        jumpsOnly.groups = .jumps
        var noGroups = ZoneNavigationKeys.default
        noGroups.groups = []
        assert(arrowsOnly.selectionKeys == expectedArrows, "the arrow group should map the four arrows to moves")
        assert(jumpsOnly.selectionKeys == expectedJumps, "the jump group should map A/S/D/F, G, and J/K/L to jumps by default")
        assert(
            ZoneNavigationKeys.default.selectionKeys == expectedArrows.merging(expectedJumps) { arrow, _ in arrow },
            "all groups should contribute every selection key"
        )
        assert(noGroups.selectionKeys.isEmpty, "no group should contribute no selection keys")
        assert(ZoneNavigationKeys.default.groups == [.arrows, .jumps], "the default should enable both groups")
        assert(ZoneNavigationKeys.default.moveKey == returnKey, "Return should be the default move key")
        assert(
            ZoneNavigationKey.jumps.count == 8 && Set(ZoneNavigationKey.jumps).count == 8,
            "there should be eight distinct jumps"
        )

        // Cells carry their column side and stack row; only the arrows step (so only jump keys'
        // auto-repeats are ignored).
        assert(ZoneNavigationCell.topLeft.side == .left && !ZoneNavigationCell.topLeft.isBottom, "top-left is the left column's top")
        assert(ZoneNavigationCell.bottomRight.side == .right && ZoneNavigationCell.bottomRight.isBottom, "bottom-right is the right column's bottom")
        assert(!ZoneNavigationKey.move(.up).isJump, "an arrow steps rather than jumps")
        for key in ZoneNavigationKey.jumps {
            assert(key.isJump, "\(key) should be a jump")
        }

        // MARK: - Settable keys: a rebound jump moves with its key; the arrows, Escape, unnamed
        // keys, and keys already held are rejected — by one policy behind the editor and the store

        var rebound = ZoneNavigationKeys.default
        rebound[.jump(.zone(.topLeft))] = one
        rebound[.move] = space
        assert(rebound[.jump(.zone(.topLeft))] == one && rebound.moveKey == space, "the subscript should read back what it set")
        assert(
            rebound.selectionKeys[one] == .zone(.topLeft) && rebound.selectionKeys[a] == nil,
            "a rebound jump should answer to its new key only"
        )
        assert(ZoneNavigationKeys.default.hasValidSettableKeys, "the default keys should be valid")
        assert(rebound.hasValidSettableKeys, "distinct named unreserved keys should be valid")
        assert(
            ZoneNavigationKeys.default.rejection(of: one, as: .jump(.floatingZone)) == nil,
            "a free named key should be accepted"
        )
        assert(
            ZoneNavigationKeys.default.rejection(of: a, as: .jump(.zone(.topLeft))) == nil,
            "a key is not in use by the role that already holds it"
        )
        assert(ZoneNavigationKeys.default.rejection(of: up, as: .jump(.floatingZone)) == .arrow, "an arrow is rejected")
        assert(ZoneNavigationKeys.default.rejection(of: escape, as: .move) == .escape, "Escape is rejected")
        assert(ZoneNavigationKeys.default.rejection(of: a, as: .move) == .inUse, "a jump's key is rejected for the move key")
        assert(ZoneNavigationKeys.default.rejection(of: returnKey, as: .jump(.floatingZone)) == .inUse, "the move key is rejected for a jump")
        for unnamed in [CGKeyCode(kVK_Command), CGKeyCode(kVK_ANSI_Keypad5), CGKeyCode(65535)] {
            assert(
                ZoneNavigationKeys.default.rejection(of: unnamed, as: .move) == .unnamed,
                "key code \(unnamed) has no label and should be rejected"
            )
        }
        for rejected in [up, escape, CGKeyCode(kVK_Command)] {
            var invalid = ZoneNavigationKeys.default
            invalid[.jump(.floatingZone)] = rejected
            assert(!invalid.hasValidSettableKeys, "key code \(rejected) should make the keys invalid as a jump key")
            invalid = ZoneNavigationKeys.default
            invalid[.move] = rejected
            assert(!invalid.hasValidSettableKeys, "key code \(rejected) should make the keys invalid as the move key")
        }
        var duplicate = ZoneNavigationKeys.default
        duplicate[.jump(.display(ordinal: 2))] = a
        assert(!duplicate.hasValidSettableKeys, "two jumps on one key should be invalid")
        duplicate = ZoneNavigationKeys.default
        duplicate[.move] = a
        assert(!duplicate.hasValidSettableKeys, "the move key on a jump's key should be invalid")
        assert(ZoneNavigationKeys.SettableKey.all.count == 9, "the move key and the eight jumps are settable")

        // MARK: - Claimed chords: the enabled selection keys plus the move key, under the given
        // modifiers; nothing when no group is enabled

        let allClaimed = ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], keys: .default)
        assert(allClaimed.count == 13, "all groups should claim the twelve selection keys plus the move key")
        assert(
            Set(allClaimed.map(\.keyCode)).isSuperset(of: Set([kVK_UpArrow, kVK_ANSI_A, kVK_ANSI_L, kVK_Return].map(UInt32.init))),
            "all groups should claim the arrows, the jump keys, and Return"
        )
        assert(
            allClaimed.allSatisfy { $0.modifiers == UInt32(controlKey | cmdKey) },
            "claimed chords should carry the gesture's modifiers"
        )

        let arrowsClaimed = ZoneNavigationInterceptor.claimedShortcuts(for: [.option, .shift], keys: arrowsOnly)
        assert(arrowsClaimed.count == 5, "the arrow group alone should claim the arrows and the move key")
        assert(
            !arrowsClaimed.contains { $0.keyCode == UInt32(kVK_ANSI_A) },
            "a disabled jump group should not claim its keys"
        )
        assert(
            arrowsClaimed.allSatisfy { $0.modifiers == UInt32(optionKey | shiftKey) },
            "claimed chords should follow the configured modifiers"
        )
        assert(
            ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], keys: jumpsOnly).count == 9,
            "the jump group alone should claim the eight jump keys and the move key"
        )
        assert(
            ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], keys: noGroups).isEmpty,
            "with no group enabled the gesture never engages, so nothing is claimed"
        )
        let reboundClaimed = ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], keys: rebound)
        assert(
            reboundClaimed.contains { $0.keyCode == UInt32(kVK_ANSI_1) } && reboundClaimed.contains { $0.keyCode == UInt32(kVK_Space) }
                && !reboundClaimed.contains { $0.keyCode == UInt32(kVK_ANSI_A) } && !reboundClaimed.contains { $0.keyCode == UInt32(kVK_Return) },
            "claimed chords should follow the configured jump and move keys"
        )

        // MARK: - Borrowed-key shadowing: in-gesture keys act first, then earlier-borrowed keys;
        // ordinary keys don't shadow

        for keyCode in [kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Return, kVK_Escape] {
            assert(
                ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(keyCode), keys: arrowsOnly),
                "key code \(keyCode) has an in-gesture meaning and should shadow a borrowed key"
            )
        }
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(a, keys: jumpsOnly),
            "A should shadow a borrowed key when the jump keys are on"
        )
        assert(
            !ZoneNavigationInterceptor.shadowsBorrowedKey(a, keys: arrowsOnly),
            "A should not shadow a borrowed key when the jump keys are off"
        )
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(returnKey, keys: noGroups),
            "the move key shadows a borrowed key regardless of the groups"
        )
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(space, keys: rebound)
                && !ZoneNavigationInterceptor.shadowsBorrowedKey(returnKey, keys: rebound),
            "a rebound move key shadows a borrowed key, and Return then no longer does"
        )
        for keyCode in [kVK_Space, kVK_F5, kVK_Tab] {
            assert(
                !ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(keyCode), keys: .default),
                "key code \(keyCode) should not shadow a borrowed key"
            )
        }
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(
                CGKeyCode(kVK_ANSI_Equal), keys: arrowsOnly,
                earlierBorrowedKeys: [space, CGKeyCode(kVK_ANSI_Equal)]
            ),
            "a key borrowed earlier in the claim order should shadow a later borrowed key"
        )
        assert(
            !ZoneNavigationInterceptor.shadowsBorrowedKey(
                CGKeyCode(kVK_ANSI_Minus), keys: arrowsOnly,
                earlierBorrowedKeys: [space, CGKeyCode(kVK_ANSI_Equal)]
            ),
            "distinct earlier-borrowed keys should not shadow an unrelated borrowed key"
        )

        // The default borrowed keys — Space, =, -, M, in claim order — must stay reachable out
        // of the box: no default selection or move key may be one of them, and no default may
        // shadow a later one. (The claim order itself is hand-maintained, in the interceptor's
        // dispatch and the walkthrough's line order.)
        let defaultBorrowedKeys = [
            space, CGKeyCode(kVK_ANSI_Equal), CGKeyCode(kVK_ANSI_Minus), CGKeyCode(kVK_ANSI_M),
        ]
        for (claimIndex, keyCode) in defaultBorrowedKeys.enumerated() {
            assert(
                !ZoneNavigationInterceptor.shadowsBorrowedKey(
                    keyCode, keys: .default,
                    earlierBorrowedKeys: Array(defaultBorrowedKeys.prefix(claimIndex))
                ),
                "default borrowed key \(keyCode) should stay reachable with every group on"
            )
        }

        // MARK: - Persistence: defaults when unset, round-trip, unknown group bits dropped,
        // invalid settable keys fall back to the defaults while the groups stand

        let defaults = UserDefaults.standard
        let storedKeys = [
            UserDefaultsKeys.zoneNavigationKeyGroups,
            UserDefaultsKeys.zoneNavigationMoveKey,
            UserDefaultsKeys.zoneNavigationJumpKeys,
        ]
        let previousValues = storedKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(storedKeys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        func store(_ keys: ZoneNavigationKeys) {
            defaults.set(keys.groups.rawValue, forKey: UserDefaultsKeys.zoneNavigationKeyGroups)
            defaults.set(Int(keys.moveKey), forKey: UserDefaultsKeys.zoneNavigationMoveKey)
            defaults.set(ZoneNavigationKey.jumps.map { Int(keys[.jump($0)]) }, forKey: UserDefaultsKeys.zoneNavigationJumpKeys)
        }

        storedKeys.forEach { defaults.removeObject(forKey: $0) }
        assert(ZoneNavigationKeyPreferences.load() == .default, "load should return the defaults when unset")
        store(rebound)
        assert(ZoneNavigationKeyPreferences.load() == rebound, "saved keys should round-trip")
        store(noGroups)
        assert(ZoneNavigationKeyPreferences.load() == noGroups, "both groups off is a valid saved choice")
        defaults.set(ZoneNavigationKeyGroups.jumps.rawValue | (1 << 7), forKey: UserDefaultsKeys.zoneNavigationKeyGroups)
        assert(ZoneNavigationKeyPreferences.load().groups == .jumps, "unknown bits in a persisted group value should be dropped")
        var invalidStored = arrowsOnly
        invalidStored[.move] = a
        store(invalidStored)
        assert(
            ZoneNavigationKeyPreferences.load() == arrowsOnly,
            "invalid stored settable keys should fall back to the default keys, keeping the stored groups"
        )
        defaults.set([1, 2, 3], forKey: UserDefaultsKeys.zoneNavigationJumpKeys)
        assert(
            ZoneNavigationKeyPreferences.load() == arrowsOnly,
            "a stored jump-key list of the wrong length should fall back to the default keys"
        )
        store(arrowsOnly)
        defaults.set([0, 1, 2, 3, 5, 38, 40, 37, -1], forKey: UserDefaultsKeys.zoneNavigationJumpKeys)
        assert(
            ZoneNavigationKeyPreferences.load() == arrowsOnly,
            "a stored jump-key list with an extra, out-of-range entry should not pass as eight keys"
        )
        defaults.set([0, 1, 2, 3, 5, 38, 40, 70000], forKey: UserDefaultsKeys.zoneNavigationJumpKeys)
        assert(
            ZoneNavigationKeyPreferences.load() == arrowsOnly,
            "a stored jump-key list with an out-of-range entry should fall back to the default keys"
        )
        defaults.set(kVK_Command, forKey: UserDefaultsKeys.zoneNavigationMoveKey)
        defaults.set([0, 1, 2, 3, 5, 38, 40, 37], forKey: UserDefaultsKeys.zoneNavigationJumpKeys)
        assert(
            ZoneNavigationKeyPreferences.load() == arrowsOnly,
            "a stored move key with no name should fall back to the default keys"
        )

        if allPassed {
            print("ZoneNavigationChordPolicyTests: all tests passed")
        }
        return allPassed
    }
}
