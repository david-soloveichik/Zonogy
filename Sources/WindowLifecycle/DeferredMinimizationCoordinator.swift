/// Debounced minimization queue used to batch rapid window minimizations.
///
/// Used by occlusion- and focus-driven floating-zone minimization (where rapid
/// signals genuinely benefit from coalescing), the floating-zone explicit
/// `minimizeOccupant` path, and any placement that flows through
/// `WindowPlacementManager.placeNewWindow` — i.e. the entry point for "a window
/// arrived" events (external unminimizes, fresh window captures, manual capture,
/// recapture, startup, drag tear-out reassignment). Those placements pass
/// `DisplacementStrategy.deferred`, which builds a `finalizeDisplaced` closure
/// that queues here. The debounce lets a launching app drain its own queue of
/// windows to unminimize before our minimize lands, breaking the otherwise
/// infinite minimize/unminimize ping-pong (see `SPECIFICATION-IMPLEMENTATION.md`).
///
/// Zonogy-initiated single-window swaps that do not go through `placeNewWindow`
/// (Launcher, drag-drop, moves between zones) keep using a synchronous minimize
/// so the brief visual flash that the minimize can produce on the displaced
/// window happens while the incoming window is still hidden (see
/// `SingleOccupantReplacement` for the ordering rationale and what we know
/// about the flash). `MinimizeLoopGuard` is the safety net that redirects
/// synchronous minimizes to this queue when it detects the loop happening anyway.
import Foundation
protocol DeferredMinimizationCoordinatorHost: AnyObject {
    var windowController: WindowController { get }
    var sleepWakeProtectionActive: Bool { get }
    /// Returns `true` when the deferred minimization should proceed for this window/reason pair.
    /// Hosts can perform pre-minimization bookkeeping (or veto minimization entirely) here.
    func prepareForDeferredMinimization(windowId: Int, reason: String) -> Bool
    func minimizeWindowProgrammatically(_ managed: ManagedWindow, reason: String)
}

final class DeferredMinimizationCoordinator {
    private let debounceInterval: TimeInterval
    weak var host: DeferredMinimizationCoordinatorHost?

    private var pending: [(windowId: Int, reason: String)] = []
    private var timer: DispatchSourceTimer?

    init(host: DeferredMinimizationCoordinatorHost, debounceInterval: TimeInterval = 0.15) {
        self.host = host
        self.debounceInterval = debounceInterval
    }

    func queue(windowId: Int, reason: String) {
        // Deduplicate: if already queued, update the reason
        if let existingIndex = pending.firstIndex(where: { $0.windowId == windowId }) {
            pending[existingIndex] = (windowId: windowId, reason: reason)
        } else {
            pending.append((windowId: windowId, reason: reason))
        }
        scheduleTimer()
    }

    func cancel(windowId: Int) {
        guard pending.contains(where: { $0.windowId == windowId }) else {
            return
        }
        pending.removeAll { $0.windowId == windowId }
        Logger.debug("Cancelled pending minimization for window \(windowId) (reassigned before flush)")
    }

    func cancelAll(reason: String) {
        timer?.cancel()
        timer = nil

        guard !pending.isEmpty else {
            return
        }

        let count = pending.count
        pending.removeAll()
        Logger.debug("Cancelled \(count) pending deferred minimization(s) (reason: \(reason))")
    }

    private func scheduleTimer() {
        timer?.cancel()

        let newTimer = DispatchSource.makeTimerSource(queue: .main)
        newTimer.schedule(deadline: .now() + debounceInterval)
        newTimer.setEventHandler { [weak self] in
            self?.flush()
        }
        newTimer.resume()
        timer = newTimer
    }

    private func flush() {
        timer?.cancel()
        timer = nil

        guard let host else {
            pending.removeAll()
            return
        }

        guard !host.sleepWakeProtectionActive else {
            let count = pending.count
            pending.removeAll()
            Logger.debug("Deferred minimization flush skipped while sleep/wake protection is active (\(count) pending)")
            return
        }

        let windowsToMinimize = pending
        pending.removeAll()

        for (windowId, reason) in windowsToMinimize {
            guard host.prepareForDeferredMinimization(windowId: windowId, reason: reason) else {
                Logger.debug("Deferred minimization skipped for window \(windowId) (reason: \(reason))")
                continue
            }
            if let window = host.windowController.window(withId: windowId) {
                host.minimizeWindowProgrammatically(window, reason: reason)
                Logger.debug("Deferred minimization completed for window \(windowId) (reason: \(reason))")
            }
        }
    }
}
