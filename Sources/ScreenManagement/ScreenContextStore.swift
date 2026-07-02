import AppKit

/// Maintains screen contexts and ordering across all connected displays
///
/// Uses dual screen identification:
/// - CGDirectDisplayID: Internal tracking (stable across display changes)
/// - Screen index (0,1,2...): User-facing display (matches winmanmon)
final class ScreenContextStore {
    struct RebuildResult {
        struct RemovedContext {
            let displayId: CGDirectDisplayID
            let context: ScreenContext
        }

        let addedDisplayIds: [CGDirectDisplayID]
        let removedContexts: [RemovedContext]
        let updatedDisplayIds: [CGDirectDisplayID]
        /// Displays where visibleFrame changed
        let visibleFrameChangedDisplayIds: [CGDirectDisplayID]
        let orderChanged: Bool
    }

    private(set) var contexts: [CGDirectDisplayID: ScreenContext] = [:]
    private(set) var order: [CGDirectDisplayID] = []
    /// Layout style applied to newly created zone controllers (existing controllers are
    /// switched by AppController when the preference changes).
    var zoneLayoutStyle: ZoneLayoutStyle
    /// Identity and bounds of the primary display. Refreshed on every `rebuild` so the
    /// Cocoa<->Accessibility flip reference tracks resolution changes on the primary display
    /// (a stale value mis-positions every managed window vertically, on all screens).
    private(set) var primaryDisplayId: CGDirectDisplayID
    private(set) var primaryScreenBounds: CGRect

    init?(screens: [NSScreen], zoneLayoutStyle: ZoneLayoutStyle = .rightBar) {
        guard let primaryScreen = screens.first,
              let primaryId = ScreenContextStore.displayId(for: primaryScreen) else {
            return nil
        }

        self.zoneLayoutStyle = zoneLayoutStyle
        primaryDisplayId = primaryId
        primaryScreenBounds = primaryScreen.frame
        rebuild(with: screens, primaryBounds: primaryScreen.frame)
    }

    @discardableResult
    func rebuild(with screens: [NSScreen]) -> RebuildResult {
        // Refresh the primary display identity/bounds from the current topology before
        // rebuilding descriptors. Otherwise these stay frozen at the values captured in
        // `init`, and a primary-display resolution change leaves every screen's
        // screen->accessibility conversion using a stale flip reference.
        if let primaryScreen = screens.first,
           let primaryId = ScreenContextStore.displayId(for: primaryScreen) {
            primaryDisplayId = primaryId
            primaryScreenBounds = primaryScreen.frame
        }
        return rebuild(with: screens, primaryBounds: primaryScreenBounds)
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

    /// Returns a user-facing screen index for logging, with multiple fallbacks.
    func loggingIndex(for displayId: CGDirectDisplayID) -> Int {
        if let index = screenIndex(for: displayId) {
            return index
        }
        return ScreenContextStore.loggingIndex(for: displayId)
    }

    /// Static variant for contexts where the instance store is unavailable.
    static func loggingIndex(for displayId: CGDirectDisplayID) -> Int {
        if let index = screenIndex(for: displayId) {
            return index
        }
        return Int(displayId)
    }

    @discardableResult
    private func rebuild(with screens: [NSScreen], primaryBounds: CGRect) -> RebuildResult {
        let previousOrder = order
        var addedDisplayIds: [CGDirectDisplayID] = []
        var updatedDisplayIds: [CGDirectDisplayID] = []
        var visibleFrameChangedDisplayIds: [CGDirectDisplayID] = []
        var removedContexts: [RebuildResult.RemovedContext] = []

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
                let previousBounds = existing.descriptor.visibleScreenBounds
                let newBounds = descriptor.visibleScreenBounds
                existing.descriptor = descriptor

                // Trigger zone relayout if active screen area changed
                if previousBounds != newBounds {
                    existing.zoneController.updateScreenFrame(newBounds)
                    visibleFrameChangedDisplayIds.append(displayId)
                }

                updatedContexts[displayId] = existing
                updatedDisplayIds.append(displayId)
            } else {
                let zoneController = ZoneController(
                    screenFrame: descriptor.visibleScreenBounds,
                    layoutStyle: zoneLayoutStyle
                )
                updatedContexts[displayId] = ScreenContext(descriptor: descriptor, zoneController: zoneController)
                addedDisplayIds.append(displayId)
            }
            updatedOrder.append(displayId)
        }

        let removedIds = Set(contexts.keys).subtracting(updatedContexts.keys)
        for displayId in removedIds {
            if let removedContext = contexts[displayId] {
                removedContexts.append(RebuildResult.RemovedContext(displayId: displayId, context: removedContext))
            }
        }

        contexts = updatedContexts
        order = updatedOrder

        return RebuildResult(
            addedDisplayIds: addedDisplayIds,
            removedContexts: removedContexts,
            updatedDisplayIds: updatedDisplayIds,
            visibleFrameChangedDisplayIds: visibleFrameChangedDisplayIds,
            orderChanged: updatedOrder != previousOrder
        )
    }
}
