import Foundation
import AppKit

/// Determines which running applications Zonogy is allowed to manage.
extension AppController {
    internal func shouldManage(application: NSRunningApplication, visibleBundleIds: Set<String>? = nil, logRejection: Bool = false) -> Bool {
        let appDescription = "\(application.localizedName ?? "Unknown") (pid \(application.processIdentifier), bundle \(application.bundleIdentifier ?? "nil"))"

        guard !application.isTerminated else {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - application is terminated") }
            return false
        }
        if application.processIdentifier == getpid() {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - same PID as Zonogy") }
            return false
        }

        // Determine the effective bundle ID - either from NSRunningApplication or derived from executable path
        var bundleId = application.bundleIdentifier
        if bundleId == nil,
           let executableURL = application.executableURL {
            let processName = executableURL.lastPathComponent
            if configuration.deriveBundleIdFromPathForProcesses.contains(processName),
               let derivedBundleId = Configuration.deriveBundleId(fromExecutableURL: executableURL) {
                bundleId = derivedBundleId
                Logger.debug("shouldManage: derived bundle ID '\(derivedBundleId)' from executable path for process '\(processName)'")
            }
        }

        guard let bundleId else {
            let processName = application.executableURL?.lastPathComponent ?? "unknown"
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - no bundle identifier (process '\(processName)' not in deriveBundleIdFromPathForProcesses or no bundle found in path)") }
            return false
        }

        if let visibleBundleIds = visibleBundleIds,
           !visibleBundleIds.contains(bundleId) {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - not in visible bundle IDs") }
            return false
        }
        if configuration.ignoredBundleIdentifiers.contains(bundleId) {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - in ignored bundle identifiers") }
            return false
        }
        if application.activationPolicy != .regular &&
            !windowController.applicationExceptionPolicy.ignoresActivationPolicy(forBundleIdentifier: bundleId) {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - activationPolicy is \(application.activationPolicy.rawValue), not .regular") }
            return false
        }
        if isXpcOrHelperProcess(application) {
            if logRejection { Logger.debug("shouldManage: rejecting \(appDescription) - is XPC or helper process") }
            return false
        }
        return true
    }

    internal func bundleIdsWithVisibleWindows() -> Set<String> {
        // Use .excludeDesktopElements without .optionOnScreenOnly to include minimized windows
        // This allows us to track apps that only have minimized windows for the launcher
        guard let windowInfoList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var bundleIds: Set<String> = []
        for info in windowInfoList {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: ownerPid) else {
                continue
            }
            // Use native bundle ID if available, otherwise try to derive from executable path
            if let bundleId = app.bundleIdentifier {
                bundleIds.insert(bundleId)
            } else if let executableURL = app.executableURL {
                let processName = executableURL.lastPathComponent
                if configuration.deriveBundleIdFromPathForProcesses.contains(processName),
                   let derivedBundleId = Configuration.deriveBundleId(fromExecutableURL: executableURL) {
                    bundleIds.insert(derivedBundleId)
                }
            }
        }
        return bundleIds
    }

    private func isXpcOrHelperProcess(_ application: NSRunningApplication) -> Bool {
        guard let url = application.bundleURL else {
            return false
        }

        let path = url.path
        return path.hasSuffix(".xpc") ||
            path.contains("/Contents/XPCServices/") ||
            path.contains(".xpc/")
    }
}
