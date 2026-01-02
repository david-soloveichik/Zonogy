import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Tracks Dock geometry changes and emits snapshots suitable for hover/click gating.
///
/// Updates are triggered by Dock Accessibility notifications and coalesced to avoid excessive work.
final class DockFrameMonitor {
    struct State: Equatable {
        var dockFrame: CGRect?
        var isDockVisible: Bool
    }

    var onStateChange: ((State) -> Void)?

    private let detector = DockWindowFrameDetector()
    private var lastState: State?
    private let queue = DispatchQueue(label: "com.zonogy.dockFrameMonitor", qos: .utility)
    private let refreshCoalesceInterval: TimeInterval
    private let animationSettleDelay: TimeInterval
    private var axNotificationMonitor: DockAXNotificationMonitor?
    private var refreshRequested = false
    private var refreshScheduled = false
    private var settleWorkItem: DispatchWorkItem?

    init(refreshCoalesceInterval: TimeInterval = 0.05, animationSettleDelay: TimeInterval = 0.25) {
        self.refreshCoalesceInterval = max(0.01, min(refreshCoalesceInterval, 2.0))
        self.animationSettleDelay = max(0.01, min(animationSettleDelay, 2.0))
    }

    func start() {
        guard axNotificationMonitor == nil else { return }

        let monitor = DockAXNotificationMonitor()
        monitor.onEvent = { [weak self] event in
            self?.handleDockEvent(event)
        }
        axNotificationMonitor = monitor
        monitor.start()

        requestRefresh(delay: 0)
    }

    func stop() {
        axNotificationMonitor?.stop()
        axNotificationMonitor = nil

        queue.async { [weak self] in
            guard let self else { return }
            self.refreshRequested = false
            self.refreshScheduled = false
            self.settleWorkItem?.cancel()
            self.settleWorkItem = nil
        }
        lastState = nil
    }

    func refreshNow() {
        requestRefresh(delay: 0)
    }

    private func requestRefresh(delay: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshRequested = true
            self.scheduleRefreshIfNeeded(delay: delay)
        }
    }

    private func handleDockEvent(_ event: DockAXNotificationMonitor.Event) {
        requestRefresh(delay: 0)

        if event.notification == (kAXSelectedChildrenChangedNotification as String) {
            scheduleSettleRefresh()
        }
    }

    private func scheduleSettleRefresh() {
        queue.async { [weak self] in
            guard let self else { return }

            settleWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.refresh()
            }
            settleWorkItem = workItem
            queue.asyncAfter(deadline: .now() + animationSettleDelay, execute: workItem)
        }
    }

    private func scheduleRefreshIfNeeded(delay: TimeInterval) {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard self.refreshRequested else { return }
            self.refreshRequested = false
            self.refresh()
            if self.refreshRequested {
                self.scheduleRefreshIfNeeded(delay: self.refreshCoalesceInterval)
            }
        }
    }

    private func refresh() {
        let snapshot = detector.currentDockWindowSnapshot()
        let next = State(
            dockFrame: snapshot?.frame,
            isDockVisible: snapshot != nil
        )

        guard next != lastState else { return }
        lastState = next
        logStateChange(snapshot: snapshot)

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(next)
        }
    }

    private func logStateChange(snapshot: DockWindowFrameDetector.Snapshot?) {
        if let snapshot {
            Logger.debug("DockFrameMonitor: dock frame=\(snapshot.frame)")
        } else {
            Logger.debug("DockFrameMonitor: Dock not found")
        }
    }
}
