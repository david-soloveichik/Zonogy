/// Launch-at-login settings wiring.

import Foundation

extension AppController {
    internal var isLaunchAtLoginEnabledInSettings: Bool {
        LaunchAtLoginPreferencesStore.isEnabled
    }

    internal func setLaunchAtLoginEnabledFromSettings(_ enabled: Bool) {
        do {
            try LaunchAtLoginPreferencesStore.setEnabled(enabled)
            Logger.debug("LaunchAtLogin: settings updated enabled=\(enabled)")
        } catch {
            Logger.debug("LaunchAtLogin: failed to update enabled=\(enabled) error=\(error)")
        }
    }
}
