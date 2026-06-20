import Foundation

/// Guardrail tests for CmdTab targeting mode defaults, persistence, and the retarget-gating policy.
enum CmdTabBehaviorPreferencesStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("CmdTabBehaviorPreferencesStoreTests: \(message)")
                allPassed = false
            }
        }

        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.cmdTabActiveWindowTargetingMode
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        assert(
            CmdTabBehaviorPreferencesStore.loadTargetingMode() == .off,
            "CmdTab targeting should default to off when unset"
        )

        for mode in CmdTabActiveWindowTargetingMode.allCases {
            CmdTabBehaviorPreferencesStore.saveTargetingMode(mode)
            assert(
                CmdTabBehaviorPreferencesStore.loadTargetingMode() == mode,
                "saved CmdTab targeting mode should round-trip \(mode)"
            )
        }

        defaults.set(999, forKey: key)
        assert(
            CmdTabBehaviorPreferencesStore.loadTargetingMode() == .off,
            "invalid CmdTab targeting raw value should fall back to the default"
        )

        // Retarget-gating policy: off never retargets; current-app-only retargets only the
        // app-specific (Cmd-`) shortcut; all-windows retargets both shortcuts.
        assert(!CmdTabActiveWindowTargetingMode.off.appliesRetargeting(in: .allWindows),
               "off should not retarget the all-windows shortcut")
        assert(!CmdTabActiveWindowTargetingMode.off.appliesRetargeting(in: .currentAppOnly),
               "off should not retarget the current-app shortcut")
        assert(!CmdTabActiveWindowTargetingMode.currentAppOnly.appliesRetargeting(in: .allWindows),
               "current-app-only should not retarget the all-windows shortcut")
        assert(CmdTabActiveWindowTargetingMode.currentAppOnly.appliesRetargeting(in: .currentAppOnly),
               "current-app-only should retarget the current-app shortcut")
        assert(CmdTabActiveWindowTargetingMode.allWindows.appliesRetargeting(in: .allWindows),
               "all-windows should retarget the all-windows shortcut")
        assert(CmdTabActiveWindowTargetingMode.allWindows.appliesRetargeting(in: .currentAppOnly),
               "all-windows should retarget the current-app shortcut")

        if allPassed {
            print("CmdTabBehaviorPreferencesStoreTests: all tests passed")
        }
        return allPassed
    }
}
