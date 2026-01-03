/// Polls cursor position to dismiss the DockMenu after the cursor leaves both the Dock and the DockMenu panel.

import Foundation

/// Runs a lightweight polling timer (scheduled in common run loop modes) that triggers dismissal when the cursor
/// remains outside a "safe region" for a configurable grace period.
final class DockMenuDismissalPoller {
    private let graceInterval: TimeInterval
    private let pollInterval: TimeInterval

    var isCursorInSafeRegion: (() -> Bool)?
    var onGraceExpired: (() -> Void)?

    private var timer: Timer?
    private var outsideSince: TimeInterval?

    init(graceInterval: TimeInterval = 0.2, pollInterval: TimeInterval = 0.05) {
        self.graceInterval = graceInterval
        self.pollInterval = pollInterval
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        outsideSince = nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        outsideSince = nil
    }

    private func tick() {
        guard let isCursorInSafeRegion else { return }

        if isCursorInSafeRegion() {
            outsideSince = nil
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        if outsideSince == nil {
            outsideSince = now
            return
        }

        guard let outsideSince else { return }
        if now - outsideSince >= graceInterval {
            self.outsideSince = nil
            onGraceExpired?()
        }
    }
}
