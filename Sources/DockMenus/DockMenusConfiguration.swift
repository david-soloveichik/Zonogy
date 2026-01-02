import Foundation

/// Configures DockMenus enablement and debug behavior.
struct DockMenusConfiguration: Decodable {
    let enabled: Bool?
    let debugDockFrameOverlay: Bool?
    let refreshCoalesceIntervalSeconds: Double?

    init(enabled: Bool?, debugDockFrameOverlay: Bool?, refreshCoalesceIntervalSeconds: Double?) {
        self.enabled = enabled
        self.debugDockFrameOverlay = debugDockFrameOverlay
        self.refreshCoalesceIntervalSeconds = refreshCoalesceIntervalSeconds
    }

    var isEnabled: Bool {
        enabled == true
    }

    var showsDockFrameOverlay: Bool {
        debugDockFrameOverlay == true
    }

    /// Coalesces refresh work triggered by Dock Accessibility notifications (not a polling interval).
    var refreshCoalesceInterval: TimeInterval {
        let value = refreshCoalesceIntervalSeconds ?? 0.05
        return max(0.01, min(value, 2.0))
    }

    static let disabled = DockMenusConfiguration(enabled: false, debugDockFrameOverlay: false, refreshCoalesceIntervalSeconds: nil)
}
