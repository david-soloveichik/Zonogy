import AppKit

/// Manages lifecycle and reuse of placeholder windows across zones.
/// Placeholders are owned directly by this coordinator (no windowId, not in registry).
final class PlaceholderCoordinator {
    enum HideReason {
        case replacedByWindow
        case idle
    }

    weak var delegate: PlaceholderCoordinatorDelegate?

    private let placeholderManager: PlaceholderManager

    /// Pool of hidden placeholders available for reuse.
    private var placeholderPool: [PlaceholderWindow] = []

    /// Active placeholders by zone key.
    private var activePlaceholders: [ZoneKey: PlaceholderWindow] = [:]

    init(placeholderManager: PlaceholderManager) {
        self.placeholderManager = placeholderManager
    }

    /// Number of currently active (visible) placeholders.
    var activePlaceholderCount: Int {
        activePlaceholders.count
    }

    /// Synchronize placeholders to match the current zone layout.
    /// Creates/shows placeholders for empty zones, hides them for occupied zones.
    func syncPlaceholders(
        screenOrder: [CGDirectDisplayID],
        excludedZones: Set<ZoneKey>,
        contextProvider: (CGDirectDisplayID) -> PlaceholderCoordinatorScreenContext?,
        shouldSuppressPlaceholder: (ZoneKey) -> Bool
    ) {
        var neededKeys = Set<ZoneKey>()

        // Process each zone
        for screenId in screenOrder {
            guard let context = contextProvider(screenId) else { continue }
            let zoneController = context.zoneController

            for zone in zoneController.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                let isExcluded = excludedZones.contains(key)

                // Case A: Zone is occupied by an external window
                if zone.occupantWindowId != nil {
                    // Hide any placeholder for this zone
                    if let placeholder = zone.placeholder {
                        hidePlaceholder(placeholder, for: key, reason: .replacedByWindow)
                        zone.placeholder = nil
                    }
                    continue
                }

                // Case B: Zone is empty but suppressed (e.g., UnderCovers)
                if shouldSuppressPlaceholder(key) {
                    if let placeholder = zone.placeholder {
                        hidePlaceholder(placeholder, for: key, reason: .idle)
                        zone.placeholder = nil
                    }
                    continue
                }

                // Case C: Zone is empty and needs a placeholder
                neededKeys.insert(key)
                let displayFrame = context.displayFrame(for: zone)

                if let placeholder = zone.placeholder {
                    // Already has one, update and show
                    placeholder.update(screenId: screenId, zoneIndex: zone.index)
                    delegate?.placeholderCoordinator(self, prepareToShow: placeholder, at: displayFrame, on: context.descriptor, isExcluded: isExcluded)
                } else {
                    // Needs one. Try to reuse or create.
                    let placeholder = obtainPlaceholder(for: key, frame: displayFrame, on: context.descriptor)
                    zone.placeholder = placeholder
                    delegate?.placeholderCoordinator(self, prepareToShow: placeholder, at: displayFrame, on: context.descriptor, isExcluded: isExcluded)
                }
            }
        }

        // Clean up active placeholders that are no longer needed
        for (key, placeholder) in activePlaceholders where !neededKeys.contains(key) {
            hidePlaceholder(placeholder, for: key, reason: .idle)

            if let context = contextProvider(key.screenId),
               let zone = context.zoneController.zone(at: key.index) {
                zone.placeholder = nil
            }
        }
    }

    /// Get or create a placeholder for a zone.
    private func obtainPlaceholder(for key: ZoneKey, frame: CGRect, on screen: ScreenDescriptor) -> PlaceholderWindow {
        // Check if we already have one active for this key
        if let existing = activePlaceholders[key] {
            existing.update(screenId: key.screenId, zoneIndex: key.index)
            return existing
        }

        // Try to reuse from pool
        let placeholder: PlaceholderWindow
        if let reusable = placeholderPool.popLast() {
            reusable.update(screenId: key.screenId, zoneIndex: key.index)
            placeholder = reusable
            Logger.debug("Reusing placeholder for zone \(key.index) on screen \(ScreenContextStore.loggingIndex(for: key.screenId))")
        } else {
            placeholder = placeholderManager.createPlaceholder(frame: frame, zoneIndex: key.index, on: screen)
            Logger.debug("Created new placeholder for zone \(key.index) on screen \(ScreenContextStore.loggingIndex(for: key.screenId))")
        }

        activePlaceholders[key] = placeholder
        return placeholder
    }

    /// Hide a placeholder and return it to the pool.
    private func hidePlaceholder(_ placeholder: PlaceholderWindow, for key: ZoneKey, reason: HideReason) {
        delegate?.placeholderCoordinator(self, prepareToHide: placeholder, reason: reason)
        placeholder.hide()
        activePlaceholders.removeValue(forKey: key)
        placeholderPool.append(placeholder)
    }

    /// Immediately hide a placeholder for the provided zone key, if active.
    /// Returns true when a placeholder was found and hidden.
    @discardableResult
    func hidePlaceholder(for key: ZoneKey, reason: HideReason) -> Bool {
        guard let placeholder = activePlaceholders[key] else {
            return false
        }
        hidePlaceholder(placeholder, for: key, reason: reason)
        return true
    }

    /// Clear all placeholder mappings for a specific screen.
    /// Used when zones are reorganized (added/removed) to prevent stale mappings.
    func clearMappingsForScreen(_ screenId: CGDirectDisplayID) {
        let keysToRemove = activePlaceholders.keys.filter { $0.screenId == screenId }
        for key in keysToRemove {
            if let placeholder = activePlaceholders.removeValue(forKey: key) {
                placeholder.hide()
                placeholderPool.append(placeholder)
            }
        }
    }

    /// Apply a resize from a placeholder drag.
    func applyResize(zoneKey: ZoneKey, placeholderFrame: CGRect, context: PlaceholderCoordinatorScreenContext, finalize: Bool) {
        guard let zone = context.zoneController.zone(at: zoneKey.index) else { return }
        let zoneFrame = context.zoneFrame(fromPlaceholderFrame: placeholderFrame, zone: zone)
        guard context.zoneController.resizeZone(at: zoneKey.index, to: zoneFrame) else { return }
        delegate?.placeholderCoordinator(self, didResizeZone: zoneKey, finalize: finalize)
    }

    /// Forget a placeholder (called when zone is removed).
    /// This is a no-op now since placeholders are managed by zones directly.
    func forget(zoneKey: ZoneKey) {
        if let placeholder = activePlaceholders.removeValue(forKey: zoneKey) {
            placeholder.close()
        }
    }
}

// MARK: - Delegate Protocol

protocol PlaceholderCoordinatorDelegate: AnyObject {
    /// Called when a placeholder should be shown at a frame.
    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToShow placeholder: PlaceholderWindow,
        at frame: CGRect,
        on descriptor: ScreenDescriptor,
        isExcluded: Bool
    )

    /// Called when a placeholder should be hidden.
    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToHide placeholder: PlaceholderWindow,
        reason: PlaceholderCoordinator.HideReason
    )

    /// Called when a zone was resized via placeholder drag.
    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        didResizeZone key: ZoneKey,
        finalize: Bool
    )
}

// MARK: - Context

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
