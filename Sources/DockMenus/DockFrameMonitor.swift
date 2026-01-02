import Foundation
import AppKit
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
    private var axNotificationMonitor: DockAXNotificationMonitor?
    private var refreshRequested = false
    private var refreshScheduled = false

    init(refreshCoalesceInterval: TimeInterval = 0.05) {
        self.refreshCoalesceInterval = max(0.01, min(refreshCoalesceInterval, 2.0))
    }

    func start() {
        guard axNotificationMonitor == nil else { return }

        let monitor = DockAXNotificationMonitor()
        monitor.onEvent = { [weak self] _ in
            self?.requestRefresh(delay: self?.refreshCoalesceInterval ?? 0.05)
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
            let source: String
            switch snapshot.windowNumber {
            case -2:
                source = "axWindows"
            case -3:
                source = "axHitTest"
            default:
                source = "cgwindow"
            }
            Logger.debug(
                "DockFrameMonitor: dock (\(source)) onScreen=\(snapshot.isOnScreen) " +
                "alpha=\(String(format: "%.2f", snapshot.alpha)) frame=\(snapshot.frame)"
            )
        } else {
            Logger.debug("DockFrameMonitor: Dock window not found")
        }
    }
}
