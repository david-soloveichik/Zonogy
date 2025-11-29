/// Window validation and exponential-backoff retry management for destroyed window detection
import Foundation
import AppKit

struct ValidationRetry {
    let pid: pid_t
    let reason: String
    let bundleId: String?
    var attempt: Int = 0
    var workItem: DispatchWorkItem?

    var isActive: Bool {
        workItem != nil && !workItem!.isCancelled
    }
}

protocol ValidationRetryManagerDelegate: AnyObject {
    func hasManagedWindows(for pid: pid_t) -> Bool
    func pruneDestroyedWindowsForPid(_ pid: pid_t) -> [Int]
    func removeWindowFromAllZones(windowId: Int, reason: String, retarget: Bool)
    func activationWorkaroundIfNeeded(for pid: pid_t, excludingWindowIds: Set<Int>, reason: String)
    func syncWindowsToZones(excluding excludedZones: Set<ZoneKey>)
}

class ValidationRetryManager {
    weak var delegate: ValidationRetryManagerDelegate?

    private var validationRetries: [pid_t: ValidationRetry] = [:]
    private let retryDelays: [TimeInterval] = [0.2, 0.4, 0.8, 1.6, 3.2]

    // MARK: - Public Interface

    func validateWindowsForApplication(pid: pid_t, reason: String = "unspecified") -> [Int] {
        guard let delegate = delegate else { return [] }

        let destroyedWindowIds = delegate.pruneDestroyedWindowsForPid(pid)

        // Handle destroyed windows
        if !destroyedWindowIds.isEmpty {
            Logger.debug("Validated pid \(pid) (\(reason)): pruned \(destroyedWindowIds.count) destroyed window(s)")
            cancelValidationRetry(for: pid)  // Success - no more retries needed

            for windowId in destroyedWindowIds {
                delegate.removeWindowFromAllZones(windowId: windowId, reason: "validate-application", retarget: true)
            }
            delegate.activationWorkaroundIfNeeded(
                for: pid,
                excludingWindowIds: Set(destroyedWindowIds),
                reason: "validate-\(reason)"
            )
            delegate.syncWindowsToZones(excluding: [])
            return destroyedWindowIds
        }

        // No destroyed windows found
        let isRetry = reason.hasPrefix("retry")

        // Check PID hasn't been reused (for non-retry calls)
        if !isRetry, let existing = validationRetries[pid], let expectedBundleId = existing.bundleId {
            let currentBundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if currentBundleId != expectedBundleId {
                Logger.debug("PID \(pid) reused (was \(expectedBundleId), now \(currentBundleId ?? "nil")), clearing stale entry")
                cancelValidationRetry(for: pid)
                return []
            }
        }

        // Log non-retry validations
        if !isRetry {
            let hasWindows = delegate.hasManagedWindows(for: pid)
            if hasWindows {
                Logger.debug("Validated pid \(pid) (\(reason)): 0 destroyed, windows still managed, scheduling retry")
            } else {
                Logger.debug("Validated pid \(pid) (\(reason)): no windows to manage")
            }
        }

        // Schedule retry if needed
        if delegate.hasManagedWindows(for: pid) {
            let retryReason = isRetry ? validationRetries[pid]?.reason ?? reason : reason
            scheduleValidationRetry(for: pid, reason: retryReason)
        } else {
            cancelValidationRetry(for: pid)
        }

        return []
    }

    func cancelValidationRetry(for pid: pid_t) {
        guard let retry = validationRetries.removeValue(forKey: pid) else {
            return
        }
        retry.workItem?.cancel()
    }

    func cancelAllValidationRetries() {
        for (_, retry) in validationRetries {
            retry.workItem?.cancel()
        }
        let count = validationRetries.count
        validationRetries.removeAll()
        if count > 0 {
            Logger.debug("Cancelled \(count) pending validation retry/retries")
        }
    }

    // MARK: - Private Implementation

    private func scheduleValidationRetry(for pid: pid_t, reason: String) {
        guard let delegate = delegate,
              delegate.hasManagedWindows(for: pid) else {
            cancelValidationRetry(for: pid)
            return
        }

        // Check for existing retry
        if let existing = validationRetries[pid] {
            if existing.isActive {
                // Don't interrupt an active retry unless the reason changed
                if existing.reason != reason {
                    Logger.debug("Validation reason changed from '\(existing.reason)' to '\(reason)' for pid \(pid), restarting retry")
                    cancelValidationRetry(for: pid)
                    // Fall through to schedule new retry
                } else {
                    return // Already have an active retry
                }
            }
        }

        // Create or update retry entry
        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        var retry = validationRetries[pid] ?? ValidationRetry(
            pid: pid,
            reason: reason,
            bundleId: bundleId
        )

        // Check if exhausted
        if retry.attempt >= retryDelays.count {
            Logger.debug("Validation retry exhausted for pid \(pid) after \(retry.attempt) attempts (reason: \(retry.reason))")
            cancelValidationRetry(for: pid)
            return
        }

        // Schedule the retry
        let delay = retryDelays[retry.attempt]
        let nextAttempt = retry.attempt + 1

        Logger.debug("Scheduling retry #\(nextAttempt) for pid \(pid) in \(String(format: "%.1f", delay))s (reason: \(retry.reason))")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // Verify PID hasn't been reused
            if let expectedBundleId = bundleId,
               let currentBundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               currentBundleId != expectedBundleId {
                Logger.debug("PID \(pid) reused (was \(expectedBundleId), now \(currentBundleId)), cancelling")
                self.cancelValidationRetry(for: pid)
                return
            }

            Logger.debug("Executing retry #\(nextAttempt) for pid \(pid) (reason: \(retry.reason))")

            let destroyed = self.validateWindowsForApplication(pid: pid, reason: "retry-\(retry.reason)-\(nextAttempt)")

            // Clear work item and decide next step
            self.validationRetries[pid]?.workItem = nil
            self.validationRetries[pid]?.attempt = nextAttempt

            if destroyed.isEmpty && self.delegate?.hasManagedWindows(for: pid) == true {
                self.scheduleValidationRetry(for: pid, reason: retry.reason)
            } else {
                let message = destroyed.isEmpty
                    ? "All windows validated successfully"
                    : "Pruned \(destroyed.count) destroyed window(s)"
                Logger.debug("Retry complete for pid \(pid): \(message)")
                self.cancelValidationRetry(for: pid)
            }
        }

        retry.workItem?.cancel()
        retry.workItem = workItem
        retry.attempt = nextAttempt - 1  // Will be incremented to nextAttempt when executed

        validationRetries[pid] = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
