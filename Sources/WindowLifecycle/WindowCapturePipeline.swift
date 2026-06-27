import AppKit

/// Coordinates window capture requests and retry scheduling for external applications.
final class WindowCapturePipeline {
    struct RetryConfiguration {
        let delays: [TimeInterval]
        static let `default` = RetryConfiguration(delays: [0.25, 0.5, 1.0, 2.0, 4.0])
    }

    struct CaptureRequest {
        let application: NSRunningApplication
        let notifyDelegate: Bool
        let allowExisting: Bool
    }

    weak var delegate: WindowCapturePipelineDelegate?

    private let windowController: WindowController
    private let retryConfiguration: RetryConfiguration
    private var retryStates: [pid_t: RetryState] = [:]

    init(windowController: WindowController, retryConfiguration: RetryConfiguration = .default) {
        self.windowController = windowController
        self.retryConfiguration = retryConfiguration
    }

    /// Capture windows for the supplied application. Returns any captured windows immediately.
    @discardableResult
    func capture(_ request: CaptureRequest) -> [ManagedWindow] {
        guard delegate?.capturePipeline(self, shouldManage: request.application) ?? true else {
            return []
        }

        let pid = request.application.processIdentifier
        let description = request.application.bundleIdentifier ?? request.application.localizedName ?? "unknown-app"
        Logger.debug("CapturePipeline: capturing windows for \(description) (pid \(pid)), allowExisting: \(request.allowExisting)")

        let result = windowController.captureWindows(
            for: request.application,
            notifyDelegate: request.notifyDelegate,
            allowExisting: request.allowExisting
        )

        if result.needsRetry {
            scheduleRetry(for: request.application, hintBundleId: request.application.bundleIdentifier)
        } else {
            cancelRetry(forPid: pid)
        }

        Logger.debug("CapturePipeline: capture complete for \(description) (pid \(pid)): \(result.windows.count) window(s), needsRetry: \(result.needsRetry)")

        return result.windows
    }

    /// Schedule a retry for the given pid. Creates a new attempt if one is not already pending.
    func requestRetry(forPid pid: pid_t, bundleId: String?) {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            Logger.debug("CapturePipeline: unable to request retry for pid \(pid); application no longer running")
            cancelRetry(forPid: pid)
            return
        }
        // A fresh external trigger restarts the backoff instead of inheriting a prior capture's
        // attempt count, so rapid triggers don't escalate the delay before the new window is adopted.
        retryStates[pid]?.attempt = 0
        scheduleRetry(for: application, hintBundleId: bundleId)
    }

    /// Cancel any pending retry for a pid.
    func cancelRetry(forPid pid: pid_t) {
        guard var state = retryStates.removeValue(forKey: pid) else {
            return
        }
        state.cancel()
    }

    /// Cancel all pending retries.
    func cancelAllRetries() {
        for (pid, var state) in retryStates {
            Logger.debug("CapturePipeline: cancelling retry for pid \(pid)")
            state.cancel()
        }
        retryStates.removeAll()
    }

    private func scheduleRetry(for application: NSRunningApplication, hintBundleId: String?) {
        let pid = application.processIdentifier
        var state = retryStates[pid] ?? RetryState()

        if state.bundleId == nil {
            state.bundleId = hintBundleId
        } else if let hint = hintBundleId, let existing = state.bundleId, existing != hint {
            Logger.debug("CapturePipeline: bundle changed for pid \(pid) (was \(existing), now \(hint)); resetting retry attempts")
            state.bundleId = hint
            state.resetAttempts()
        }

        guard state.attempt < retryConfiguration.delays.count else {
            let description = state.bundleId ?? hintBundleId ?? "unknown-bundle-identifier"
            Logger.debug("CapturePipeline: retry exhausted for pid \(pid) (bundle \(description))")
            state.cancel()
            retryStates.removeValue(forKey: pid)
            return
        }

        let delay = retryConfiguration.delays[state.attempt]
        state.attempt += 1

        state.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // Clear the stored work item before executing.
            if var stored = self.retryStates[pid] {
                stored.workItem = nil
                self.retryStates[pid] = stored
            }

            guard let refreshedApplication = NSRunningApplication(processIdentifier: pid) else {
                Logger.debug("CapturePipeline: retry cancelled for pid \(pid); application no longer running")
                self.retryStates.removeValue(forKey: pid)
                return
            }

            if let expectedBundle = self.retryStates[pid]?.bundleId,
               let currentBundle = refreshedApplication.bundleIdentifier,
               expectedBundle != currentBundle {
                Logger.debug("CapturePipeline: retry cancelled for pid \(pid); bundle changed from \(expectedBundle) to \(currentBundle)")
                self.retryStates.removeValue(forKey: pid)
                return
            }

            guard self.delegate?.capturePipeline(self, shouldManage: refreshedApplication) ?? true else {
                self.retryStates.removeValue(forKey: pid)
                return
            }

            let request = CaptureRequest(application: refreshedApplication, notifyDelegate: true, allowExisting: false)
            self.capture(request)
        }

        state.workItem = workItem
        retryStates[pid] = state

        Logger.debug("CapturePipeline: scheduling retry \(state.attempt) for pid \(pid) in \(delay) second(s)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

protocol WindowCapturePipelineDelegate: AnyObject {
    func capturePipeline(_ pipeline: WindowCapturePipeline, shouldManage application: NSRunningApplication) -> Bool
}

private struct RetryState {
    var bundleId: String?
    var attempt: Int = 0
    var workItem: DispatchWorkItem?

    mutating func resetAttempts() {
        attempt = 0
        cancel()
    }

    mutating func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
