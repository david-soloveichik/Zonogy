import Foundation
import AppKit

/// Zone layout style preference plumbing: persistence and live re-tiling on change.
extension AppController {
    internal var zoneLayoutStyleInSettings: ZoneLayoutStyle {
        screenContextStore.zoneLayoutStyle
    }

    internal func setZoneLayoutStyleFromSettings(_ style: ZoneLayoutStyle) {
        guard style != screenContextStore.zoneLayoutStyle else {
            return
        }
        ZoneLayoutStylePreferencesStore.saveStyle(style)
        screenContextStore.zoneLayoutStyle = style
        applyZoneLayoutStyle(style)
    }

    /// Re-tile every screen under the new layout style: zones keep their indexes and
    /// occupants, zones beyond the new maximum are removed (their windows minimized),
    /// and layout-driven UI refreshes.
    private func applyZoneLayoutStyle(_ style: ZoneLayoutStyle) {
        Logger.debug("Applying zone layout style \(style.rawValue) to all screens")
        windowController.cancelAllAccessibilityFrameRetries()

        for (screenId, context) in screenContexts {
            endUnderCovers(on: screenId, reason: "layout-style-change", recreatePlaceholders: false)
            clearRememberedManualResizeSizes(on: screenId, reason: "layout-style-change")
            let removedWindowIds = context.zoneController.setLayoutStyle(style)
            placeholderCoordinator.clearPlaceholdersForScreen(screenId)
            for windowId in removedWindowIds {
                if let managed = windowController.window(withId: windowId) {
                    windowPlacementManager.handleWindowAfterZoneRemoval(managed)
                }
            }
        }

        syncWindowsToZones()
        targetedZoneManager.ensureTargetedZone(reason: "layout-style-change")
        activeFitRefreshAfterZoneTopologyChange(reason: "layout-style-change")
        refreshIndicators()
        refreshResizeHandles()
    }
}
