import Foundation

/// Set to true to show a blue debug border around the Dock frame.
private let kShowDebugDockFrameOverlay = false

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
        debugDockFrameOverlay ?? kShowDebugDockFrameOverlay
    }

    static let disabled = DockMenusConfiguration(enabled: false, debugDockFrameOverlay: false)
}
