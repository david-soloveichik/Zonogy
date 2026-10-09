/// Applies experimental preferences and publishes their runtime status to Preferences.
import Foundation

extension Notification.Name {
    static let instantMinimizeStatusChanged = Notification.Name("Zonogy.instantMinimizeStatusChanged")
}

extension AppController {
    internal func startInstantMinimize() {
        instantMinimizeController.onChange = {
            NotificationCenter.default.post(name: .instantMinimizeStatusChanged, object: nil)
        }
        instantMinimizeController.start(enabled: ExperimentalPreferencesStore.loadInstantMinimizeEnabled())
        // Recovery can discover an active patch even if the checkbox preference was lost.
        ExperimentalPreferencesStore.saveInstantMinimizeEnabled(instantMinimizeController.isEnabled)
    }

    internal func setInstantMinimizeEnabledFromSettings(_ enabled: Bool) {
        ExperimentalPreferencesStore.saveInstantMinimizeEnabled(enabled)
        Logger.debug("Experimental: disable minimize and restore animations=\(enabled)")
        instantMinimizeController.setEnabled(enabled)
    }
}
