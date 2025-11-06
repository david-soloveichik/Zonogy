import AppKit

/// Maintains screen contexts and ordering across all connected displays
///
/// Uses dual screen identification:
/// - CGDirectDisplayID: Internal tracking (stable across display changes)
/// - Screen index (0,1,2...): User-facing display (matches winmanmon)
final class ScreenContextStore {
    private(set) var contexts: [CGDirectDisplayID: ScreenContext] = [:]
    private(set) var order: [CGDirectDisplayID] = []
    let primaryDisplayId: CGDirectDisplayID
    let primaryScreenBounds: CGRect

    init?(screens: [NSScreen]) {
        guard let primaryScreen = screens.first,
              let primaryId = ScreenContextStore.displayId(for: primaryScreen) else {
            return nil
        }

        primaryDisplayId = primaryId
        primaryScreenBounds = primaryScreen.frame
        rebuild(with: screens, primaryBounds: primaryScreen.frame)
    }

    func rebuild(with screens: [NSScreen]) {
        rebuild(with: screens, primaryBounds: primaryScreenBounds)
    }

    func context(for displayId: CGDirectDisplayID) -> ScreenContext? {
        contexts[displayId]
    }

    func descriptor(for displayId: CGDirectDisplayID) -> ScreenDescriptor? {
        contexts[displayId]?.descriptor
    }

    func zoneController(for displayId: CGDirectDisplayID) -> ZoneController? {
        contexts[displayId]?.zoneController
    }

    static func displayId(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    /// Convert CGDirectDisplayID to user-friendly screen index (0,1,2...)
    /// Returns the index in NSScreen.screens array, or nil if displayId not found
    func screenIndex(for displayId: CGDirectDisplayID) -> Int? {
        return order.firstIndex(of: displayId)
    }

    /// Convert CGDirectDisplayID to user-friendly screen index (0,1,2...)
    /// This uses a fresh scan of NSScreen.screens for accuracy
    static func screenIndex(for displayId: CGDirectDisplayID) -> Int? {
        for (index, screen) in NSScreen.screens.enumerated() {
            if let screenId = ScreenContextStore.displayId(for: screen), screenId == displayId {
                return index
            }
        }
        return nil
    }

    private func rebuild(with screens: [NSScreen], primaryBounds: CGRect) {
        var updatedContexts: [CGDirectDisplayID: ScreenContext] = [:]
        var updatedOrder: [CGDirectDisplayID] = []

        for screen in screens {
            guard let displayId = ScreenContextStore.displayId(for: screen) else {
                continue
            }

            let descriptor = ScreenDescriptor(
                displayId: displayId,
                localizedName: screen.localizedName,
                cocoaBounds: screen.frame,
                visibleCocoaBounds: screen.visibleFrame,
                primaryBounds: primaryBounds
            )

            if var existing = contexts[displayId] {
                existing.descriptor = descriptor
                updatedContexts[displayId] = existing
            } else {
                let zoneController = ZoneController(screenFrame: descriptor.visibleScreenBounds)
                updatedContexts[displayId] = ScreenContext(descriptor: descriptor, zoneController: zoneController)
            }
            updatedOrder.append(displayId)
        }

        contexts = updatedContexts
        order = updatedOrder
    }
}
