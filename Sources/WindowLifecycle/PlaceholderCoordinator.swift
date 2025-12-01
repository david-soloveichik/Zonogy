import AppKit

/// Manages lifecycle and reuse of placeholder windows across zones.
final class PlaceholderCoordinator {
    enum HideReason {
        case replacedByWindow
        case idle
    }

    weak var delegate: PlaceholderCoordinatorDelegate?

    private let windowController: WindowController

    init(windowController: WindowController) {
        self.windowController = windowController
    }

    /// Synchronize placeholders to match the current zone layout.
    func syncPlaceholders(
        existingWindows: [ManagedWindow],
        screenOrder: [CGDirectDisplayID],
        excludedZones: Set<ZoneKey>,
        contextProvider: (CGDirectDisplayID) -> PlaceholderCoordinatorScreenContext?,
        shouldSuppressPlaceholder: (ZoneKey) -> Bool
    ) {
        // 1. Identify all currently known placeholder windows
        let allPlaceholders = existingWindows.filter { $0.isPlaceholder }
        var availablePlaceholders = allPlaceholders 
        var assignedWindowIds = Set<Int>()

        // 2. Validate existing assignments in zones
        for screenId in screenOrder {
            guard let context = contextProvider(screenId) else { continue }
            for zone in context.zoneController.allZones {
                if let pid = zone.placeholderWindowId {
                    // Check if this window still exists
                    if windowController.window(withId: pid) != nil {
                        assignedWindowIds.insert(pid)
                        // Remove from available list so we don't reuse it elsewhere
                        availablePlaceholders.removeAll { $0.windowId == pid }
                    } else {
                        // Window is gone, clear assignment
                        context.zoneController.setPlaceholder(windowId: nil, forZoneIndex: zone.index)
                    }
                }
            }
        }
        
        // 3. Process each zone: Show, Hide, Assign, or Suppress (UnderCovers)
        for screenId in screenOrder {
            guard let context = contextProvider(screenId) else { continue }
            let zoneController = context.zoneController

            for zone in zoneController.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                let isExcluded = excludedZones.contains(key)
                
                // Case A: Zone is occupied by a managed window
                if zone.windowId != nil {
                    if let pid = zone.placeholderWindowId,
                       let placeholder = windowController.window(withId: pid) {
                        // Hide the assigned placeholder
                        delegate?.placeholderCoordinator(self, prepareToHide: placeholder, reason: .replacedByWindow)
                        clearManagedZone(for: placeholder)
                    }
                    continue
                }

                // Case B: Zone is empty, may need a placeholder unless suppressed (e.g., UnderCovers)
                let displayFrame = context.displayFrame(for: zone)

                // UnderCovers and other suppression: ensure any existing placeholder is hidden and not recreated.
                if shouldSuppressPlaceholder(key) {
                    if let pid = zone.placeholderWindowId,
                       let placeholder = windowController.window(withId: pid) {
                        delegate?.placeholderCoordinator(self, prepareToHide: placeholder, reason: .idle)
                        clearManagedZone(for: placeholder)
                    }
                    zoneController.setPlaceholder(windowId: nil, forZoneIndex: zone.index)
                    continue
                }

                if let pid = zone.placeholderWindowId,
                   let placeholder = windowController.window(withId: pid) {
                    // Already has one, update and show
                    record(placeholder: placeholder, key: key)
                    delegate?.placeholderCoordinator(self, prepareToShow: placeholder, at: displayFrame, on: context.descriptor, isExcluded: isExcluded)
                } else {
                    // Needs one. Try to reuse or create.
                    let placeholder: ManagedWindow
                    
                    if let reusable = availablePlaceholders.popLast() {
                        placeholder = reusable
                        Logger.debug("Reusing placeholder window \(placeholder.windowId) for zone \(zone.index) on screen \(context.descriptor.displayId)")
                    } else {
                        placeholder = windowController.createPlaceholderWindow(frame: displayFrame, zoneIndex: zone.index, on: context.descriptor)
                    }
                    
                    // Assign to zone
                    zoneController.setPlaceholder(windowId: placeholder.windowId, forZoneIndex: zone.index)
                    assignedWindowIds.insert(placeholder.windowId)
                    
                    record(placeholder: placeholder, key: key)
                    delegate?.placeholderCoordinator(self, prepareToShow: placeholder, at: displayFrame, on: context.descriptor, isExcluded: isExcluded)
                }
            }
        }

        // 4. Clean up unassigned placeholders
        for placeholder in availablePlaceholders {
            delegate?.placeholderCoordinator(self, prepareToHide: placeholder, reason: .idle)
            clearManagedZone(for: placeholder)
            forget(windowId: placeholder.windowId)
        }
    }

    func record(placeholder: ManagedWindow, key: ZoneKey) {
        windowController.refreshPlaceholderMetadata(placeholder, screenId: key.screenId, zoneIndex: key.index)
    }

    func forget(windowId: Int) {
        // No longer needed to remove from local map, but keeping method signature if AppController calls it.
        // AppController calls this when window closes. 
        // But here we primarily manage "forgetting" by clearing zone assignment.
        // If AppController calls this, it means the window is GONE.
        // We should ensure it is removed from any zone.
        // But we don't have easy access to ZoneController here without context.
        // However, syncPlaceholders handles validation of non-existent windows.
    }

    /// Clear all placeholder mappings for a specific screen
    /// Used when zones are reorganized (added/removed) to prevent stale mappings
    func clearMappingsForScreen(_ screenId: CGDirectDisplayID) {
        // With the new architecture, mappings are in the Zone objects.
        // If we want to clear them (e.g. to force regeneration), we would need to iterate zones.
        // But usually we want to preserve them.
        // This method might be vestigial or needed for specific reset scenarios.
        // If we leave it empty, 'syncPlaceholders' will still validate/reassign.
        // But to be safe and ensure metadata is cleared:
        // We can't clear zone.placeholderWindowId here easily without the ZoneController.
        // We can rely on syncPlaceholders.
    }

    func applyResize(zoneKey: ZoneKey, placeholderFrame: CGRect, context: PlaceholderCoordinatorScreenContext, finalize: Bool) {
        guard let zone = context.zoneController.zone(at: zoneKey.index) else { return }
        let zoneFrame = context.zoneFrame(fromPlaceholderFrame: placeholderFrame, zone: zone)
        guard context.zoneController.resizeZone(at: zoneKey.index, to: zoneFrame) else { return }
        delegate?.placeholderCoordinator(self, didResizeZone: zoneKey, finalize: finalize)
    }

    private func clearManagedZone(for managed: ManagedWindow) {
        delegate?.placeholderCoordinator(self, clearManagedZoneFor: managed)
    }
}

protocol PlaceholderCoordinatorDelegate: AnyObject {
    func placeholderCoordinator(_ coordinator: PlaceholderCoordinator, prepareToShow placeholder: ManagedWindow, at frame: CGRect, on descriptor: ScreenDescriptor, isExcluded: Bool)
    func placeholderCoordinator(_ coordinator: PlaceholderCoordinator, prepareToHide placeholder: ManagedWindow, reason: PlaceholderCoordinator.HideReason)
    func placeholderCoordinator(_ coordinator: PlaceholderCoordinator, didResizeZone key: ZoneKey, finalize: Bool)
    func placeholderCoordinator(_ coordinator: PlaceholderCoordinator, clearManagedZoneFor managed: ManagedWindow)
}

struct PlaceholderCoordinatorScreenContext {
    let descriptor: ScreenDescriptor
    let zoneController: ZoneController
    let displayFrameForZone: (Zone) -> CGRect
    let placeholderToZoneFrame: (CGRect, Zone) -> CGRect

    func displayFrame(for zone: Zone) -> CGRect {
        displayFrameForZone(zone)
    }

    func zoneFrame(fromPlaceholderFrame frame: CGRect, zone: Zone) -> CGRect {
        placeholderToZoneFrame(frame, zone)
    }
}
