/// Owns the optional Dock patch's lifecycle, crash recovery, verification, and quit cleanup.
import Foundation

final class InstantMinimizeController {
    typealias Cancel = () -> Void

    struct Environment {
        var prerequisiteFailure: () -> String?
        var currentDock: () -> InstantMinimizeDock?
        var loadActivation: () -> InstantMinimizeActivation?
        var saveActivation: (InstantMinimizeActivation?) -> Void
        var watchExit: (InstantMinimizeDock, @escaping () -> Void) -> Cancel
        var inject: (InstantMinimizeDock, Bool, @escaping (InstantMinimizeResult) -> Void) -> Cancel
        var restart: (InstantMinimizeDock) -> String?
        var schedule: (TimeInterval, @escaping () -> Void) -> Cancel
        var now: () -> TimeInterval
    }

    private let environment: Environment
    private(set) var isEnabled = false
    private(set) var status = "Off."
    private(set) var hasError = false
    var isActive: Bool { activatedAt != nil }
    var onChange: (() -> Void)?

    private var generation = 0
    private var dock: InstantMinimizeDock?
    private var needsCleanup = false
    private var isInjecting = false
    private var activatedAt: TimeInterval?
    private var cancelExit: Cancel?
    private var cancelInjection: Cancel?
    private var cancelRetry: Cancel?

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// A verified patch lasts for that Dock process, even when Zonogy crashes. Recover it
    /// before consulting the checkbox, so a lost preference cannot leave an active patch unmanaged.
    func start(enabled: Bool) {
        if let activation = environment.loadActivation(), activation.dock == environment.currentDock() {
            isEnabled = true
            watchDock(activation.dock)
            needsCleanup = true
            activatedAt = activation.verifiedAt
            Logger.debug("InstantMinimize: resumed the previously verified Dock patch")
            update("Active.")
            return
        }
        environment.saveActivation(nil)
        setEnabled(enabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        stopWork()
        if let error = restoreDock() {
            update("Could not restore animations: \(error)", error: true)
            return
        }
        guard enabled else {
            update("Off.")
            return
        }
        if let error = environment.prerequisiteFailure() {
            fail(error)
            return
        }
        findDock(attemptsRemaining: 8)
    }

    /// Synchronous cancellation and SIGTERM delivery; no async work is left to run after quitting.
    /// The caller leaves the saved preference alone so the next launch can enable the feature.
    func shutdown() {
        isEnabled = false
        stopWork()
        if let error = restoreDock() {
            Logger.error("InstantMinimize: quit cleanup failed: \(error)")
        }
    }

    private func findDock(attemptsRemaining: Int) {
        guard isEnabled else { return }
        guard let candidate = environment.currentDock() else {
            guard attemptsRemaining > 0 else {
                fail("Dock is unavailable. Turn this setting off and on to retry.")
                return
            }
            update("Waiting for Dock…")
            let token = generation
            cancelRetry = environment.schedule(0.5) { [weak self] in
                guard let self, self.generation == token else { return }
                self.cancelRetry = nil
                self.findDock(attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }
        watchDock(candidate)
        inject(candidate, authorized: false)
    }

    private func watchDock(_ candidate: InstantMinimizeDock) {
        dock = candidate
        let token = generation
        cancelExit = environment.watchExit(candidate) { [weak self] in
            guard let self, self.generation == token else { return }
            self.dockExited()
        }
    }

    private func inject(_ candidate: InstantMinimizeDock, authorized: Bool) {
        isInjecting = true
        // Until an attempt returns a definite no-change result, cancellation must assume it
        // could still apply its patches. Restarting this exact Dock also defeats late approval.
        needsCleanup = true
        update(authorized ? "Waiting for administrator approval…" : "Applying and verifying…")
        let token = generation
        cancelInjection = environment.inject(candidate, authorized) { [weak self] result in
            guard let self, self.generation == token, self.dock == candidate else { return }
            self.cancelInjection = nil
            self.isInjecting = false
            self.needsCleanup = result.needsDockRestart
            Logger.debug("InstantMinimize: \(result.status.rawValue): \(result.message)")
            switch result.status {
            case .active:
                let verifiedAt = self.environment.now()
                self.environment.saveActivation(.init(dock: candidate, verifiedAt: verifiedAt))
                self.needsCleanup = true
                self.activatedAt = verifiedAt
                self.update("Active.")
            case .permissionDenied where !authorized:
                self.inject(candidate, authorized: true)
            case .permissionDenied, .failed:
                self.fail(result.failureDescription)
            }
        }
    }

    private func dockExited() {
        let unstable = isInjecting || activatedAt.map { environment.now() - $0 < 5 } == true
        // The old process has gone, so no cleanup may target its replacement.
        environment.saveActivation(nil)
        needsCleanup = false
        dock = nil
        stopWork()
        guard isEnabled else { return }
        if unstable {
            fail("Dock exited during or just after activation. Automatic retries stopped; turn this setting off and on to retry.")
        } else {
            findDock(attemptsRemaining: 8)
        }
    }

    private func fail(_ message: String) {
        stopWork() // Cancel the exit watcher before cleanup, so our own restart cannot reinject.
        let hadPossiblePatches = needsCleanup
        let cleanupError = restoreDock()
        var detail = message
        if let cleanupError {
            detail += " Could not restart Dock: \(cleanupError)"
        } else if hadPossiblePatches {
            detail += " Dock was restarted to remove any partial patch."
        }
        update(detail, error: true)
    }

    private func stopWork() {
        generation += 1
        cancelRetry?()
        cancelRetry = nil
        cancelExit?()
        cancelExit = nil
        cancelInjection?()
        cancelInjection = nil
        isInjecting = false
        activatedAt = nil
    }

    private func restoreDock() -> String? {
        if needsCleanup, let dock, let error = environment.restart(dock) {
            // Retain the identity for another cleanup attempt on disable or quit.
            return error
        }
        environment.saveActivation(nil)
        needsCleanup = false
        dock = nil
        return nil
    }

    private func update(_ text: String, error: Bool = false) {
        status = text
        hasError = error
        if error { Logger.error("InstantMinimize: \(text)") }
        onChange?()
    }
}
