/// Per-screen "settle timer" scheduler for occupancy-change auto-save.
///
/// Fed the latest per-screen occupancy signatures after each full zone sync, it (re)arms a delay
/// whenever a screen's occupancy changes. If an arrangement survives the delay unchanged, the
/// settle callback fires so a snapshot can be captured — semantically a snapshot taken a short
/// while after the arrangement settled, which also serves as the correct "pre-change" capture for
/// whatever change comes next (including externally-initiated ones Zonogy learns of too late).
import CoreGraphics
import Foundation

final class WinShotOccupancyAutoSaveScheduler {
    private var lastSignatures: [CGDirectDisplayID: WinShotSnapshotOccupancySignature] = [:]
    private var pendingWorkItems: [CGDirectDisplayID: DispatchWorkItem] = [:]

    /// Reconcile against the latest per-screen occupancy signatures.
    /// - Parameters:
    ///   - currentSignatures: signatures for screens currently worth tracking (occupied, not paused).
    ///   - delay: settle threshold in seconds.
    ///   - onSettle: invoked on the main queue once a screen's arrangement has been stable for `delay`.
    func handleSync(
        currentSignatures: [CGDirectDisplayID: WinShotSnapshotOccupancySignature],
        delay: TimeInterval,
        onSettle: @escaping (CGDirectDisplayID, WinShotSnapshotOccupancySignature) -> Void
    ) {
        let decision = WinShotOccupancyAutoSavePlan.decide(
            previous: lastSignatures,
            current: currentSignatures
        )

        for screenId in decision.screensToCancel {
            pendingWorkItems[screenId]?.cancel()
            pendingWorkItems[screenId] = nil
            lastSignatures[screenId] = nil
        }

        for screenId in decision.screensToArm {
            guard let armedSignature = currentSignatures[screenId] else {
                continue
            }
            pendingWorkItems[screenId]?.cancel()
            // Carry the armed signature so the callback can confirm the arrangement actually
            // persisted for the delay before saving it.
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingWorkItems[screenId] = nil
                onSettle(screenId, armedSignature)
            }
            pendingWorkItems[screenId] = workItem
            lastSignatures[screenId] = armedSignature
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        // Unchanged screens keep their tracked signature and their existing (pending or
        // already-fired) timer, so a long-lived arrangement is captured exactly once.
    }

    /// Cancel all pending timers and forget tracked signatures (feature disabled or settings changed).
    func reset() {
        for workItem in pendingWorkItems.values {
            workItem.cancel()
        }
        pendingWorkItems.removeAll()
        lastSignatures.removeAll()
    }
}
