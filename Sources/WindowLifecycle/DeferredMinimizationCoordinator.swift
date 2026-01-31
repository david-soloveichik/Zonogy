/// Debounced minimization queue used to batch rapid window displacements.
///
/// This is intentionally shared between tiled-zone and temporary-zone displacement so the
/// replacement pipelines can be uniform and avoid redundant AX churn.
import Foundation
protocol DeferredMinimizationCoordinatorHost: AnyObject {
    var windowController: WindowController { get }
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

        let windowsToMinimize = pending
        pending.removeAll()

        for (windowId, reason) in windowsToMinimize {
            if let window = host.windowController.window(withId: windowId) {
                host.minimizeWindowProgrammatically(window, reason: reason)
                Logger.debug("Deferred minimization completed for window \(windowId) (reason: \(reason))")
            }
        }
    }
}
