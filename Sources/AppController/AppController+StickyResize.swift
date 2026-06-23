/// Sticky Resize preference wiring and remembered tiled-window size state.

import AppKit
import Foundation

extension AppController {
    internal var isStickyResizeEnabledInSettings: Bool {
        stickyResizeEnabled
    }

    internal func setStickyResizeEnabledFromSettings(_ enabled: Bool) {
        guard stickyResizeEnabled != enabled else {
            return
        }

        Logger.debug("StickyResize: settings updated enabled=\(enabled)")
        stickyResizeEnabled = enabled
        StickyResizePreferencesStore.saveEnabled(enabled)

        if !enabled {
            manualResizeDetachedWindowIds.removeAll()
            rememberedManualResizeSizesByWindowId.removeAll()
        }

        exitRevealMode(reason: "sticky-resize-setting-changed")
        syncWindowsToZones()
        handleActiveFitActivationCandidate(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    internal func stickyResizeFrameResolution(
        for managed: ManagedWindow,
        zone: Zone,
        controller: ZoneController
    ) -> StickyResizeFramePolicy.Resolution {
        let rememberedSize = rememberedStickyResizeSize(for: managed.windowId)
        return StickyResizeFramePolicy.nonRevealedFrame(
            zoneFrame: frameWithMargin(for: zone, in: controller),
            rememberedSize: rememberedSize,
            stickyResizeEnabled: stickyResizeEnabled,
            isActive: isWindowActive(managed)
        )
    }

    internal func rememberedStickyResizeSize(for windowId: Int) -> CGSize? {
        guard stickyResizeEnabled,
              let size = rememberedManualResizeSizesByWindowId[windowId],
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return size
    }

    internal func rememberManualResizeSize(
        for windowId: Int,
        size: CGSize,
        reason: String
    ) {
        guard stickyResizeEnabled,
              size.width > 0,
              size.height > 0 else {
            return
        }

        rememberedManualResizeSizesByWindowId[windowId] = size
        Logger.debug("StickyResize: remembered size \(size) for window \(windowId) (reason: \(reason))")
    }

    @discardableResult
    internal func clearRememberedManualResizeSize(
        for windowId: Int,
        reason: String
    ) -> CGSize? {
        manualResizeDetachedWindowIds.remove(windowId)
        let removed = rememberedManualResizeSizesByWindowId.removeValue(forKey: windowId)
        if let removed {
            Logger.debug("StickyResize: cleared remembered size \(removed) for window \(windowId) (reason: \(reason))")
        }
        return removed
    }

    internal func clearRememberedManualResizeSizes(
        on screenId: CGDirectDisplayID,
        reason: String
    ) {
        let matchingWindowIds = windowController.allWindows.compactMap { managed -> Int? in
            guard managed.zoneIndex != nil else {
                return nil
            }

            let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
            return managedScreenId == screenId ? managed.windowId : nil
        }

        guard !matchingWindowIds.isEmpty else {
            return
        }

        manualResizeDetachedWindowIds.subtract(matchingWindowIds)

        var clearedWindowIds: [Int] = []
        for windowId in matchingWindowIds {
            if rememberedManualResizeSizesByWindowId.removeValue(forKey: windowId) != nil {
                clearedWindowIds.append(windowId)
            }
        }

        if !clearedWindowIds.isEmpty {
            Logger.debug(
                "StickyResize: cleared remembered sizes on \(screenContextStore.logDescription(for: screenId)) " +
                "for windows \(clearedWindowIds) (reason: \(reason))"
            )
        }
    }

    @discardableResult
    internal func restoreStickyResizeFrameIfNeeded(
        for managed: ManagedWindow,
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: String
    ) -> Bool {
        // While ActiveFit has this window in reveal mode it owns the frame (and already applies the
        // remembered sticky size as its reveal candidate). Restoring the rest frame here only undoes
        // the reveal, and ActiveFit — which runs right after on every focus change — shifts it back;
        // a burst of focus/main-window notifications turns that round-trip into visible thrashing.
        if activeFitState?.windowId == managed.windowId {
            Logger.debug("StickyResize: skipping restore for window \(managed.windowId); ActiveFit owns reveal frame")
            return false
        }

        guard let context = screenContexts[screenId],
              let descriptor = descriptor(for: screenId),
              let zone = context.zoneController.zone(at: zoneIndex) else {
            return false
        }

        let resolution = stickyResizeFrameResolution(
            for: managed,
            zone: zone,
            controller: context.zoneController
        )
        guard resolution.usesRememberedSize else {
            return false
        }

        Logger.debug(
            "StickyResize: restoring remembered size for window \(managed.windowId) " +
            "to zone \(zone.index) on \(screenContextStore.logDescription(for: screenId)) (reason: \(reason))"
        )
        windowController.moveWindow(managed, to: resolution.frame, on: descriptor)
        manualResizeDetachedWindowIds.insert(managed.windowId)
        return true
    }

    @discardableResult
    internal func applyRememberedStickyResizeFrameIfAvailable(
        for managed: ManagedWindow,
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: String
    ) -> Bool {
        guard let rememberedSize = rememberedStickyResizeSize(for: managed.windowId),
              let context = screenContexts[screenId],
              let descriptor = descriptor(for: screenId),
              let zone = context.zoneController.zone(at: zoneIndex) else {
            return false
        }

        let frame = CGRect(
            origin: frameWithMargin(for: zone, in: context.zoneController).origin,
            size: rememberedSize
        )
        Logger.debug(
            "StickyResize: applying remembered size for window \(managed.windowId) " +
            "to zone \(zone.index) on \(screenContextStore.logDescription(for: screenId)) (reason: \(reason))"
        )
        windowController.moveWindow(managed, to: frame, on: descriptor)
        manualResizeDetachedWindowIds.insert(managed.windowId)
        return true
    }
}
