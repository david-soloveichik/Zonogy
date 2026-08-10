import Carbon
import Foundation

/// Guardrail tests for the zone-navigation key policy: the keyset presets' direction maps, the
/// reserved chords the shortcut editors keep table shortcuts off, the keys that shadow a borrowed
/// key (Show Launcher, Add Zone, Remove Zone), and keyset persistence.
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

        // MARK: - Keysets: arrows always active; letter presets map their cluster shapes

        let expectedArrows: [CGKeyCode: ZoneNavigationDirection] = [
            CGKeyCode(kVK_UpArrow): .up,
            CGKeyCode(kVK_DownArrow): .down,
            CGKeyCode(kVK_LeftArrow): .left,
            CGKeyCode(kVK_RightArrow): .right,
        ]
        for keyset in ZoneNavigationKeyset.allCases {
            for (keyCode, direction) in expectedArrows {
                assert(
                    keyset.directionKeys[keyCode] == direction,
                    "\(keyset.rawValue) should map arrow key \(keyCode) to \(direction)"
                )
            }
            let expectedCount = keyset == .arrows ? 4 : 8
            assert(
                keyset.directionKeys.count == expectedCount,
                "\(keyset.rawValue) should have \(expectedCount) selection keys"
            )
        }

        let hjkl = ZoneNavigationKeyset.hjkl.directionKeys
        assert(
            hjkl[CGKeyCode(kVK_ANSI_H)] == .left && hjkl[CGKeyCode(kVK_ANSI_J)] == .down
                && hjkl[CGKeyCode(kVK_ANSI_K)] == .up && hjkl[CGKeyCode(kVK_ANSI_L)] == .right,
            "hjkl should map Vim directions"
        )
        let wasd = ZoneNavigationKeyset.wasd.directionKeys
        assert(
            wasd[CGKeyCode(kVK_ANSI_W)] == .up && wasd[CGKeyCode(kVK_ANSI_A)] == .left
                && wasd[CGKeyCode(kVK_ANSI_S)] == .down && wasd[CGKeyCode(kVK_ANSI_D)] == .right,
            "wasd should map gaming directions"
        )
        let ijkl = ZoneNavigationKeyset.ijkl.directionKeys
        assert(
            ijkl[CGKeyCode(kVK_ANSI_I)] == .up && ijkl[CGKeyCode(kVK_ANSI_J)] == .left
                && ijkl[CGKeyCode(kVK_ANSI_K)] == .down && ijkl[CGKeyCode(kVK_ANSI_L)] == .right,
            "ijkl should mirror the arrow cluster on the right hand"
        )
        assert(ZoneNavigationKeyset.defaultKeyset == .arrows, "default keyset should be arrows")

        // MARK: - Reserved chords: the selection keys plus Return, under the given modifiers

        let arrowsReserved = ZoneNavigationInterceptor.reservedShortcuts(for: [.control, .command], keyset: .arrows)
        assert(arrowsReserved.count == 5, "arrows should claim exactly five chords")
        assert(
            Set(arrowsReserved.map(\.keyCode)) == Set([kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Return].map(UInt32.init)),
            "arrows should reserve the arrow keys and Return"
        )
        assert(
            arrowsReserved.allSatisfy { $0.modifiers == UInt32(controlKey | cmdKey) },
            "reserved chords should carry the gesture's modifiers"
        )

        let hjklReserved = ZoneNavigationInterceptor.reservedShortcuts(for: [.option, .shift], keyset: .hjkl)
        assert(hjklReserved.count == 9, "a letter keyset should claim nine chords (arrows + letters + Return)")
        assert(
            Set(hjklReserved.map(\.keyCode)).isSuperset(of: Set([kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L].map(UInt32.init))),
            "hjkl should reserve its letters"
        )
        assert(
            hjklReserved.allSatisfy { $0.modifiers == UInt32(optionKey | shiftKey) },
            "reserved chords should follow the configured modifiers"
        )

        // MARK: - Borrowed-key shadowing: in-gesture keys act first, then earlier-borrowed keys;
        // ordinary keys don't shadow

        for keyCode in [kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Return, kVK_Escape] {
            assert(
                ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(keyCode), keyset: .arrows),
                "key code \(keyCode) has an in-gesture meaning and should shadow a borrowed key"
            )
        }
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(kVK_ANSI_L), keyset: .hjkl),
            "L should shadow a borrowed key under hjkl"
        )
        assert(
            !ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(kVK_ANSI_L), keyset: .arrows),
            "L should not shadow a borrowed key under arrows"
        )
        assert(
            !ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(kVK_ANSI_L), keyset: .wasd),
            "L should not shadow a borrowed key under wasd"
        )
        for keyCode in [kVK_Space, kVK_F5, kVK_Tab] {
            assert(
                !ZoneNavigationInterceptor.shadowsBorrowedKey(CGKeyCode(keyCode), keyset: .hjkl),
                "key code \(keyCode) should not shadow a borrowed key"
            )
        }
        assert(
            ZoneNavigationInterceptor.shadowsBorrowedKey(
                CGKeyCode(kVK_ANSI_Equal), keyset: .arrows,
                earlierBorrowedKeys: [CGKeyCode(kVK_Space), CGKeyCode(kVK_ANSI_Equal)]
            ),
            "a key borrowed earlier in the claim order should shadow a later borrowed key"
        )
        assert(
            !ZoneNavigationInterceptor.shadowsBorrowedKey(
                CGKeyCode(kVK_ANSI_Minus), keyset: .arrows,
                earlierBorrowedKeys: [CGKeyCode(kVK_Space), CGKeyCode(kVK_ANSI_Equal)]
            ),
            "distinct earlier-borrowed keys should not shadow an unrelated borrowed key"
        )

        // MARK: - Keyset persistence: default when unset, round-trip, invalid fallback

        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.zoneNavigationKeyset
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        assert(ZoneNavigationKeysetPreferences.load() == .arrows, "load should return arrows when unset")
        defaults.set(ZoneNavigationKeyset.wasd.rawValue, forKey: key)
        assert(ZoneNavigationKeysetPreferences.load() == .wasd, "a saved keyset should round-trip")
        defaults.set("not-a-keyset", forKey: key)
        assert(ZoneNavigationKeysetPreferences.load() == .arrows, "an invalid persisted keyset should fall back to arrows")

        if allPassed {
            print("ZoneNavigationChordPolicyTests: all tests passed")
        }
        return allPassed
    }
}
