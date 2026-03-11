/// Debounced minimization queue used to batch rapid window displacements.
///
/// This is intentionally shared between tiled-zone and floating-zone displacement so the
/// replacement pipelines can be uniform and avoid redundant AX churn.
import Foundation
protocol DeferredMinimizationCoordinatorHost: AnyObject {
    var windowController: WindowController { get }
    var screensAsleep: Bool { get }
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

        guard !host.screensAsleep else {
            let count = pending.count
            pending.removeAll()
            Logger.debug("Deferred minimization flush skipped while screens are asleep (\(count) pending)")
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
