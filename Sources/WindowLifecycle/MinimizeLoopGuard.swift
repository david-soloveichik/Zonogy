/// Detects and breaks the rare placement-driven minimize/unminimize loop where Zonogy
/// minimizes a displaced window, the owning app re-unminimizes it from its own queue,
/// Zonogy places it again, displaces another window, minimizes that one, and so on.
///
/// The signal we watch for: a non-suppressed deminiaturize event for a window that
/// Zonogy itself programmatically minimized within the last `recentMinimizeWindow`.
/// When that signal fires repeatedly within `rapidWindow`, we activate "loop suspected"
/// for `loopActiveDuration` — and during that window, all programmatic minimizations
/// route through `DeferredMinimizationCoordinator` instead of running synchronously,
/// so the launching app's queue can drain before our minimize lands.
///
/// `placeNewWindow` already uses `.deferred` displacement, so this guard primarily
/// catches the Zonogy-initiated swap paths (Launcher, drag-drop, moves) on the rare
/// occasion they trigger the same loop.
import Foundation

final class MinimizeLoopGuard {
    /// Window after a programmatic minimize during which a deminiaturize is "suspicious".
    private let recentMinimizeWindow: TimeInterval = 0.5
    /// Time window over which suspicious deminiaturizes are counted toward the threshold.
    private let rapidWindow: TimeInterval = 2.0
    /// How many suspicious deminiaturizes before we declare a loop.
    private let loopThreshold: Int = 2
    /// How long the loop-suspected flag stays active after detection.
    private let loopActiveDuration: TimeInterval = 3.0
    /// Stale-entry sweep horizon for the `recentProgrammaticMinimize` map.
    private let staleHorizon: TimeInterval = 5.0

    private var recentProgrammaticMinimize: [Int: Date] = [:]
    private var rapidWindowStart: Date?
    private var rapidCount: Int = 0
    private var loopActiveUntil: Date?

    /// Whether the guard currently believes a placement-driven minimize/unminimize loop
    /// is in progress.
    var isLoopActive: Bool {
        guard let until = loopActiveUntil else { return false }
        return Date() < until
    }

    /// Record that Zonogy programmatically minimized a window. Call from
    /// `minimizeWindowProgrammatically` so the next deminiaturize for the same window
    /// can be classified as "rapid re-unminimize after our minimize".
    func recordProgrammaticMinimize(windowId: Int) {
        let now = Date()
        recentProgrammaticMinimize[windowId] = now
        sweepStaleEntries(now: now)
    }

    /// Record a non-suppressed deminiaturize event. If it arrived close on the heels
    /// of a programmatic minimize for the same window, count it toward the threshold
    /// and (when the threshold is crossed) activate the loop-suspected flag.
    /// Returns true if this call transitioned the guard from inactive to active.
    @discardableResult
    func recordExternalDeminiaturize(windowId: Int) -> Bool {
        let now = Date()
        sweepStaleEntries(now: now)

        guard let lastMinimize = recentProgrammaticMinimize[windowId],
              now.timeIntervalSince(lastMinimize) < recentMinimizeWindow else {
            return false
        }

        if let windowStart = rapidWindowStart, now.timeIntervalSince(windowStart) > rapidWindow {
            rapidCount = 0
            rapidWindowStart = nil
        }
        if rapidWindowStart == nil {
            rapidWindowStart = now
        }
        rapidCount += 1

        guard rapidCount >= loopThreshold else {
            return false
        }

        let wasActive = isLoopActive
        loopActiveUntil = now.addingTimeInterval(loopActiveDuration)
        return !wasActive
    }

    private func sweepStaleEntries(now: Date) {
        recentProgrammaticMinimize = recentProgrammaticMinimize.filter {
            now.timeIntervalSince($0.value) < staleHorizon
        }
    }
}
