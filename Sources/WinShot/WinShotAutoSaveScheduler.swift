/// Per-screen "settle timer" scheduler for "after every change" WinShot auto-save.
///
/// Fed the latest per-screen arrangement states whenever an arrangement may have changed, it
/// (re)arms a delay whenever a screen's arrangement changes. If an arrangement survives the delay
/// unchanged, the settle callback fires so a snapshot can be captured — semantically a snapshot
/// taken a short while after the arrangement settled, which also serves as the correct
/// "pre-change" capture for whatever change comes next (including externally-initiated ones Zonogy
/// learns of too late).
import CoreGraphics
import Foundation

final class WinShotAutoSaveScheduler {
    private var lastStates: [CGDirectDisplayID: WinShotArrangementState] = [:]
    private var pendingWorkItems: [CGDirectDisplayID: DispatchWorkItem] = [:]

    /// Reconcile against the latest per-screen arrangement states.
    /// - Parameters:
    ///   - currentStates: states of the screens currently worth tracking (occupied, not paused).
    ///   - delay: settle threshold in seconds.
    ///   - onSettle: invoked on the main queue once a screen's arrangement has been stable for `delay`.
    func reconcile(
        currentStates: [CGDirectDisplayID: WinShotArrangementState],
        delay: TimeInterval,
        onSettle: @escaping (CGDirectDisplayID, WinShotArrangementState) -> Void
    ) {
        let decision = WinShotAutoSavePlan.decide(previous: lastStates, current: currentStates)

        for screenId in decision.screensToCancel {
            pendingWorkItems[screenId]?.cancel()
            pendingWorkItems[screenId] = nil
            lastStates[screenId] = nil
        }

        for screenId in decision.screensToArm {
            guard let armedState = currentStates[screenId] else {
                continue
            }
            pendingWorkItems[screenId]?.cancel()
            // Carry the armed state so the callback can confirm the arrangement actually
            // persisted for the delay before saving it.
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingWorkItems[screenId] = nil
                onSettle(screenId, armedState)
            }
            pendingWorkItems[screenId] = workItem
            lastStates[screenId] = armedState
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        // Unchanged screens keep their tracked state and their existing (pending or already-fired)
        // timer, so a long-lived arrangement is captured exactly once.
    }

    /// Cancel all pending timers and forget tracked states (feature disabled or settings changed).
    func reset() {
        for workItem in pendingWorkItems.values {
            workItem.cancel()
        }
        pendingWorkItems.removeAll()
        lastStates.removeAll()
    }
}
