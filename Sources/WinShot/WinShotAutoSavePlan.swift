/// Pure decision logic for the WinShot auto-save scheduler.
///
/// Given the previously tracked per-screen arrangement states and the current ones, decides which
/// screens need their settle timer (re)started (arrangement changed or screen newly appeared) and
/// which pending timers should be cancelled (screen no longer present). This is the deterministic
/// core covered by `--self-test`; the timer mechanics live in `WinShotAutoSaveScheduler`.
import CoreGraphics

enum WinShotAutoSavePlan {
    struct Decision: Equatable {
        /// Screens whose arrangement changed since the last evaluation — (re)arm their settle timer.
        let screensToArm: Set<CGDirectDisplayID>
        /// Screens no longer present — cancel any pending settle timer and stop tracking them.
        let screensToCancel: Set<CGDirectDisplayID>
    }

    static func decide(
        previous: [CGDirectDisplayID: WinShotArrangementState],
        current: [CGDirectDisplayID: WinShotArrangementState]
    ) -> Decision {
        var screensToArm = Set<CGDirectDisplayID>()
        for (screenId, state) in current where previous[screenId] != state {
            screensToArm.insert(screenId)
        }

        var screensToCancel = Set<CGDirectDisplayID>()
        for screenId in previous.keys where current[screenId] == nil {
            screensToCancel.insert(screenId)
        }

        return Decision(screensToArm: screensToArm, screensToCancel: screensToCancel)
    }
}
