/// Settle delay settings wiring.

import Foundation

extension AppController {
    internal func setSettleDelayFromSettings(_ seconds: Int) {
        let normalized = SecondsPreference.settleDelay.normalizedSeconds(seconds)
        Logger.debug("SettleDelay: settings updated seconds=\(normalized)")
        SecondsPreference.settleDelay.saveSeconds(normalized)
        // Restart pending WinShot auto-save countdowns so the new delay takes effect right away.
        // (The delay's other uses read it whenever they need it.)
        winShotAutoSaveScheduler.reset()
        evaluateWinShotAutoSave()
    }
}
