import Foundation

/// Configures DockMenus enablement and debug behavior.
struct DockMenusConfiguration: Decodable {
    let enabled: Bool?
    let debugDockFrameOverlay: Bool?

    init(enabled: Bool?, debugDockFrameOverlay: Bool?) {
        self.enabled = enabled
        self.debugDockFrameOverlay = debugDockFrameOverlay
    }

    var isEnabled: Bool {
        enabled == true
    }

    var showsDockFrameOverlay: Bool {
        debugDockFrameOverlay ?? false
    }

    static let disabled = DockMenusConfiguration(enabled: false, debugDockFrameOverlay: false)
}
