/// Resolves application identity and running-state lookups via bundle identifiers.

import AppKit
import Foundation

enum ApplicationIdentity {
    static func bundleIdentifier(forApplicationURL url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    static func runningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    static func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    static func isRunning(bundleIdentifier: String) -> Bool {
        runningApplication(bundleIdentifier: bundleIdentifier) != nil
    }
}
