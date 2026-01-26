import AppKit

/// Zone UI interaction tracking: arms and clears the resize-handle visibility override.
extension AppController {

    internal func recordZoneUiMouseDown(mouseDownTimestamp: TimeInterval) {
        lastZoneUiMouseDownTimestamp = mouseDownTimestamp
        ensureZoneUiGlobalMouseDownMonitorInstalled()
    }

    internal func clearZoneUiMouseDownOverride(reason: String) {
        guard lastZoneUiMouseDownTimestamp != nil || zoneUiGlobalMouseDownMonitor != nil else {
            return
        }
        lastZoneUiMouseDownTimestamp = nil
        tearDownZoneUiGlobalMouseDownMonitor()
    }

    private func ensureZoneUiGlobalMouseDownMonitorInstalled() {
        guard zoneUiGlobalMouseDownMonitor == nil else {
            return
        }
        zoneUiGlobalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let clickTimestamp = event.timestamp
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let lastZoneUiTimestamp = self.lastZoneUiMouseDownTimestamp else {
                    self.clearZoneUiMouseDownOverride(reason: "global-click-no-state")
                    return
                }
                // Ignore the matching global callback for clicks that were actually on zone UI
                // (placeholders or resize handles). The next non-zone-UI click clears the override.
                if abs(clickTimestamp - lastZoneUiTimestamp) <= 0.01 {
                    return
                }
                self.clearZoneUiMouseDownOverride(reason: "global-click")
                self.refreshResizeHandles()
            }
        }
    }

    private func tearDownZoneUiGlobalMouseDownMonitor() {
        guard let monitor = zoneUiGlobalMouseDownMonitor else {
            return
        }
        NSEvent.removeMonitor(monitor)
        zoneUiGlobalMouseDownMonitor = nil
    }
}
