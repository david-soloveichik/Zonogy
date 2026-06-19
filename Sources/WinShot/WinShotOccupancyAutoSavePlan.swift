/// Pure decision logic for the occupancy-change auto-save scheduler.
///
/// Given the previously tracked per-screen occupancy signatures and the current ones, decides which
/// screens need their settle timer (re)started (signature changed or screen newly appeared) and
/// which pending timers should be cancelled (screen no longer present). This is the deterministic
/// core covered by `--self-test`; the timer mechanics live in `WinShotOccupancyAutoSaveScheduler`.
import CoreGraphics

enum WinShotOccupancyAutoSavePlan {
    struct Decision: Equatable {
        /// Screens whose occupancy changed since last sync — (re)arm their settle timer.
        let screensToArm: Set<CGDirectDisplayID>
        /// Screens no longer present — cancel any pending settle timer and stop tracking them.
        let screensToCancel: Set<CGDirectDisplayID>
    }

    static func decide(
        previous: [CGDirectDisplayID: WinShotSnapshotOccupancySignature],
        current: [CGDirectDisplayID: WinShotSnapshotOccupancySignature]
    ) -> Decision {
        var screensToArm = Set<CGDirectDisplayID>()
        for (screenId, signature) in current where previous[screenId] != signature {
            screensToArm.insert(screenId)
        }

        var screensToCancel = Set<CGDirectDisplayID>()
        for screenId in previous.keys where current[screenId] == nil {
            screensToCancel.insert(screenId)
        }

        return Decision(screensToArm: screensToArm, screensToCancel: screensToCancel)
    }
}
