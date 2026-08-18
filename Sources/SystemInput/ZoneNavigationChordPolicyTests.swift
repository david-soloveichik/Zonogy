import Carbon
import Foundation

/// Guardrail tests for the zone-navigation key policy: the selection keys the groups contribute
/// (fixed arrows, configurable jump keys), which jump keys are valid, the chords the gesture claims
/// (a table shortcut on one conflicts with it), the keys that shadow a borrowed key (Move Focused
/// Window to Destination, Show Launcher, Add Zone, Remove Zone, Minimize Focused Window),
/// persistence, and the held-key marks behind the interceptor's swallowing of a taken key until
/// its release.
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

        // MARK: - Jump keys: a rebound jump moves with its key; the arrows, Escape, unnamed keys,
        // and keys already held are rejected — by one policy behind the editor and the store

        var rebound = ZoneNavigationKeys.default
        rebound[.zone(.topLeft)] = one
        rebound[.floatingZone] = space
        assert(rebound[.zone(.topLeft)] == one && rebound[.floatingZone] == space, "the subscript should read back what it set")
        assert(
            rebound.selectionKeys[one] == .zone(.topLeft) && rebound.selectionKeys[a] == nil,
            "a rebound jump should answer to its new key only"
        )
        assert(ZoneNavigationKeys.default.hasValidJumpKeys, "the default keys should be valid")
        assert(rebound.hasValidJumpKeys, "distinct named unreserved keys should be valid")
        assert(
            ZoneNavigationKeys.default.rejection(of: one, as: .floatingZone) == nil,
            "a free named key should be accepted"
        )
        assert(
            ZoneNavigationKeys.default.rejection(of: returnKey, as: .floatingZone) == nil,
            "Return is a borrowed shortcut key, not the gesture's own, so a jump may take it"
        )
        assert(
            ZoneNavigationKeys.default.rejection(of: a, as: .zone(.topLeft)) == nil,
            "a key is not in use by the jump that already holds it"
        )
        assert(ZoneNavigationKeys.default.rejection(of: up, as: .floatingZone) == .arrow, "an arrow is rejected")
        assert(ZoneNavigationKeys.default.rejection(of: escape, as: .floatingZone) == .escape, "Escape is rejected")
        assert(ZoneNavigationKeys.default.rejection(of: a, as: .floatingZone) == .inUse, "another jump's key is rejected")
        for unnamed in [CGKeyCode(kVK_Command), CGKeyCode(kVK_ANSI_Keypad5), CGKeyCode(65535)] {
            assert(
                ZoneNavigationKeys.default.rejection(of: unnamed, as: .floatingZone) == .unnamed,
                "key code \(unnamed) has no label and should be rejected"
            )
        }
        for rejected in [up, escape, CGKeyCode(kVK_Command)] {
            var invalid = ZoneNavigationKeys.default
            invalid[.floatingZone] = rejected
            assert(!invalid.hasValidJumpKeys, "key code \(rejected) should make the keys invalid as a jump key")
        }
        var duplicate = ZoneNavigationKeys.default
        duplicate[.display(ordinal: 2)] = a
        assert(!duplicate.hasValidJumpKeys, "two jumps on one key should be invalid")

        // MARK: - Claimed chords: the enabled selection keys under the given modifiers; nothing
        // when no group is enabled. The borrowed action keys (Return, Space, =, -, M by default)
        // are their shortcuts' chords, not the gesture's.

        let allClaimed = ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], keys: .default)
        assert(allClaimed.count == 12, "all groups should claim the twelve selection keys")
        assert(
            Set(allClaimed.map(\.keyCode)).isSuperset(of: Set([kVK_UpArrow, kVK_ANSI_A, kVK_ANSI_L].map(UInt32.init))),
            "all groups should claim the arrows and the jump keys"
        )
        assert(
            !allClaimed.contains { $0.keyCode == UInt32(kVK_Return) },
            "the borrowed move key is not a chord of the gesture's own"
        )
        assert(
            allClaimed.allSatisfy { $0.modifiers == UInt32(controlKey | cmdKey) },
            "claimed chords should carry the gesture's modifiers"
        )

        let arrowsClaimed = ZoneNavigationInterceptor.claimedShortcuts(for: [.option, .shift], keys: arrowsOnly)
        assert(arrowsClaimed.count == 4, "the arrow group alone should claim the arrows")
        assert(
            !arrowsClaimed.contains { $0.keyCode == UInt32(kVK_ANSI_A) },
            "a disabled jump group should not claim its keys"
        )
        assert(
            arrowsClaimed.allSatisfy { $0.modifiers == UInt32(optionKey | shiftKey) },
            "claimed chords should follow the configured modifiers"
        )
        assert(
            ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], keys: jumpsOnly).count == 8,
            "the jump group alone should claim the eight jump keys"
        )
        assert(
            ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], keys: noGroups).isEmpty,
            "with no group enabled the gesture never engages, so nothing is claimed"
        )
        let reboundClaimed = ZoneNavigationInterceptor.claimedShortcuts(for: [.control, .command], keys: rebound)
        assert(
            reboundClaimed.contains { $0.keyCode == UInt32(kVK_ANSI_1) } && reboundClaimed.contains { $0.keyCode == UInt32(kVK_Space) }
                && !reboundClaimed.contains { $0.keyCode == UInt32(kVK_ANSI_A) } && !reboundClaimed.contains { $0.keyCode == UInt32(kVK_ANSI_G) },
            "claimed chords should follow the configured jump keys"
        )

        // MARK: - Borrowed-key shadowing: in-gesture keys act first, then earlier-borrowed keys;
        // ordinary keys don't shadow

        for keyCode in [kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Escape] {
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
            ZoneNavigationInterceptor.shadowsBorrowedKey(space, keys: rebound)
                && !ZoneNavigationInterceptor.shadowsBorrowedKey(space, keys: .default),
            "a jump rebound onto Space shadows a borrowed key on Space; the default keys don't"
        )
        for keyCode in [kVK_Return, kVK_Space, kVK_F5, kVK_Tab] {
            assert(
                !ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(keyCode), keys: .default),
                "key code \(keyCode) should not shadow a borrowed key"
            )
        }
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(
                CGKeyCode(kVK_ANSI_Equal), keys: arrowsOnly,
                earlierBorrowedKeys: [returnKey, space, CGKeyCode(kVK_ANSI_Equal)]
            ),
            "a key borrowed earlier in the claim order should shadow a later borrowed key"
        )
        assert(
            !ZoneNavigationInterceptor.shadowsBorrowedKey(
                CGKeyCode(kVK_ANSI_Minus), keys: arrowsOnly,
                earlierBorrowedKeys: [returnKey, space, CGKeyCode(kVK_ANSI_Equal)]
            ),
            "distinct earlier-borrowed keys should not shadow an unrelated borrowed key"
        )

        // The default borrowed keys — Return, Space, =, -, M, in claim order — must stay reachable
        // out of the box: no default selection key may be one of them, and no default may shadow
        // a later one. (The claim order itself is hand-maintained, in the interceptor's dispatch
        // and the walkthrough's line order.)
        let defaultBorrowedKeys = [
            returnKey, space, CGKeyCode(kVK_ANSI_Equal), CGKeyCode(kVK_ANSI_Minus), CGKeyCode(kVK_ANSI_M),
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
        // invalid jump keys fall back to the defaults while the groups stand

        let defaults = UserDefaults.standard
        let storedKeys = [
            UserDefaultsKeys.zoneNavigationKeyGroups,
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
            defaults.set(ZoneNavigationKey.jumps.map { Int(keys[$0]) }, forKey: UserDefaultsKeys.zoneNavigationJumpKeys)
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
        invalidStored[.floatingZone] = a
        store(invalidStored)
        assert(
            ZoneNavigationKeyPreferences.load() == arrowsOnly,
            "invalid stored jump keys should fall back to the default keys, keeping the stored groups"
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
        defaults.set([0, 1, 2, 3, 5, 38, 40, kVK_Command], forKey: UserDefaultsKeys.zoneNavigationJumpKeys)
        assert(
            ZoneNavigationKeyPreferences.load() == arrowsOnly,
            "a stored jump key with no name should fall back to the default keys"
        )

        // MARK: - Held keys: a swallowed fresh press marks the key until its release; its repeats
        // are swallowed and its release too; a swallowed repeat marks nothing; a fresh press of a
        // marked key means the release went unseen, so the mark is dropped and the press is not
        // treated as held

        var held = ZoneNavigationInterceptor.HeldKeys()
        assert(!held.isRepeatOfSwallowedPress(returnKey, isRepeat: true), "an unmarked key's repeat is not a held repeat")
        assert(!held.released(returnKey), "an unmarked key's release is not swallowed")

        held.swallowedPress(returnKey, isRepeat: false)
        held.swallowedPress(space, isRepeat: false)
        assert(held.isRepeatOfSwallowedPress(returnKey, isRepeat: true), "a marked key's repeat is a held repeat")
        assert(held.isRepeatOfSwallowedPress(space, isRepeat: true), "several keys can be marked at once")
        assert(!held.isRepeatOfSwallowedPress(a, isRepeat: true), "another key's repeat is unaffected")
        assert(held.released(returnKey), "a marked key's release is swallowed and clears the mark")
        assert(!held.isRepeatOfSwallowedPress(returnKey, isRepeat: true), "after the release the key is no longer held")
        assert(!held.released(returnKey), "a second release is not swallowed")
        assert(held.isRepeatOfSwallowedPress(space, isRepeat: true), "releasing one key leaves the others marked")

        held.swallowedPress(a, isRepeat: true)
        assert(!held.isRepeatOfSwallowedPress(a, isRepeat: true) && !held.released(a), "a swallowed repeat marks nothing")

        held.swallowedPress(returnKey, isRepeat: false)
        assert(!held.isRepeatOfSwallowedPress(returnKey, isRepeat: false), "a fresh press of a marked key is not a held repeat")
        assert(!held.isRepeatOfSwallowedPress(returnKey, isRepeat: true) && !held.released(returnKey), "…and it dropped the stale mark")

        held.swallowedPress(returnKey, isRepeat: false)
        held.removeAll()
        assert(!held.isRepeatOfSwallowedPress(returnKey, isRepeat: true) && !held.released(space), "removeAll drops every mark")

        if allPassed {
            print("ZoneNavigationChordPolicyTests: all tests passed")
        }
        return allPassed
    }
}
