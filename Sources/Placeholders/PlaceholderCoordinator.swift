import AppKit

/// Manages lifecycle of placeholder windows across zones.
/// Placeholders are created when needed and closed when no longer needed.
final class PlaceholderCoordinator {
    private enum SyncScope {
        case all
        case screens(Set<CGDirectDisplayID>)
    }

    enum CloseReason {
        case replacedByWindow
        case idle
    }

    weak var delegate: PlaceholderCoordinatorDelegate?

    private let placeholderManager: PlaceholderManager

    /// Active placeholders by zone key.
    private var activePlaceholders: [ZoneKey: PlaceholderWindow] = [:]

    init(placeholderManager: PlaceholderManager) {
        self.placeholderManager = placeholderManager
    }

    /// Number of currently tracked placeholders.
    var activePlaceholderCount: Int {
        activePlaceholders.count
    }

    /// Returns true if a placeholder exists for the given zone.
    func hasPlaceholder(for key: ZoneKey) -> Bool {
        activePlaceholders[key] != nil
    }

    /// Synchronize placeholders to match the current zone layout.
    /// Creates/shows placeholders for empty zones, closes them for occupied/suppressed zones.
    func syncPlaceholders(
        screenOrder: [CGDirectDisplayID],
        contextProvider: (CGDirectDisplayID) -> PlaceholderCoordinatorScreenContext?,
        shouldSuppressPlaceholder: (ZoneKey) -> Bool
    ) {
        syncPlaceholders(
            screenOrder: screenOrder,
            scope: .all,
            contextProvider: contextProvider,
            shouldSuppressPlaceholder: shouldSuppressPlaceholder
        )
    }

    /// Synchronize placeholders only for a subset of screens, preserving placeholders on all others.
    func syncPlaceholders(
        forScreens screenOrder: [CGDirectDisplayID],
        contextProvider: (CGDirectDisplayID) -> PlaceholderCoordinatorScreenContext?,
        shouldSuppressPlaceholder: (ZoneKey) -> Bool
    ) {
        syncPlaceholders(
            screenOrder: screenOrder,
            scope: .screens(Set(screenOrder)),
            contextProvider: contextProvider,
            shouldSuppressPlaceholder: shouldSuppressPlaceholder
        )
    }

    private func syncPlaceholders(
        screenOrder: [CGDirectDisplayID],
        scope: SyncScope,
        contextProvider: (CGDirectDisplayID) -> PlaceholderCoordinatorScreenContext?,
        shouldSuppressPlaceholder: (ZoneKey) -> Bool
    ) {
        var neededKeys = Set<ZoneKey>()

        // Process each zone to determine which need placeholders
        for screenId in screenOrder {
            guard let context = contextProvider(screenId) else { continue }

            for zone in context.zoneController.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)

                // Skip occupied zones and suppressed zones (e.g., UnderCovers)
                if zone.occupantWindowId != nil || shouldSuppressPlaceholder(key) {
                    continue
                }

                // Zone is empty and needs a placeholder
                neededKeys.insert(key)
                let displayFrame = context.displayFrame(for: zone)

                if let existing = activePlaceholders[key] {
                    // Already has one, update and show
                    existing.update(screenId: screenId, zoneIndex: zone.index)
                    delegate?.placeholderCoordinator(self, prepareToShow: existing, at: displayFrame, on: context.descriptor)
                } else {
                    // Needs one, create it
                    let placeholder = createPlaceholder(for: key, frame: displayFrame, on: context.descriptor)
                    delegate?.placeholderCoordinator(self, prepareToShow: placeholder, at: displayFrame, on: context.descriptor)
                }
            }
        }

        // Close placeholders that are no longer needed (collect keys first to avoid mutating while iterating)
        let keysToRemove = activePlaceholders.keys.filter { key in
            guard !neededKeys.contains(key) else { return false }
            switch scope {
            case .all:
                return true
            case .screens(let screenIds):
                return screenIds.contains(key.screenId)
            }
        }
        for key in keysToRemove {
            guard let placeholder = activePlaceholders[key] else { continue }
            let reason: CloseReason = contextProvider(key.screenId)
                .flatMap { $0.zoneController.zone(at: key.index) }
                .map { $0.occupantWindowId != nil ? .replacedByWindow : .idle } ?? .idle
            closePlaceholder(placeholder, for: key, reason: reason)
        }
    }

    /// Create a new placeholder for a zone and track it.
    private func createPlaceholder(for key: ZoneKey, frame: CGRect, on screen: ScreenDescriptor) -> PlaceholderWindow {
        let placeholder = placeholderManager.createPlaceholder(frame: frame, zoneIndex: key.index, on: screen)
        activePlaceholders[key] = placeholder
        Logger.debug("Created placeholder for zone \(key.index) on screen \(ScreenContextStore.loggingIndex(for: key.screenId))")
        return placeholder
    }

    /// Close a placeholder when it is no longer needed.
    private func closePlaceholder(_ placeholder: PlaceholderWindow, for key: ZoneKey, reason: CloseReason) {
        delegate?.placeholderCoordinator(self, prepareToClose: placeholder, reason: reason)
        placeholder.hide()
        activePlaceholders.removeValue(forKey: key)
        // Defer close() to the next run loop tick to avoid closing AppKit windows while the
        // event system is still unwinding (e.g., close button click tracking).
        DispatchQueue.main.async {
            placeholder.close()
        }
    }

    /// Immediately close a placeholder for the provided zone key, if active.
    /// Returns true when a placeholder was found and closed.
    @discardableResult
    func removePlaceholder(for key: ZoneKey, reason: CloseReason) -> Bool {
        guard let placeholder = activePlaceholders[key] else {
            return false
        }
        closePlaceholder(placeholder, for: key, reason: reason)
        return true
    }

    /// Update the targeted state on all active placeholders.
    /// Exactly one placeholder (if any) will have isTargeted=true.
    func setTargetedZone(_ key: ZoneKey?) {
        for (zoneKey, placeholder) in activePlaceholders {
            placeholder.setTargeted(zoneKey == key)
        }
    }

    /// Flash the border of the placeholder for the given zone key, if it exists.
    func flashPlaceholderBorder(for key: ZoneKey) {
        activePlaceholders[key]?.flashBorder()
    }

    /// Close and remove all placeholders for a specific screen.
    /// Used when zones are reorganized (added/removed) to prevent stale mappings.
    func clearPlaceholdersForScreen(_ screenId: CGDirectDisplayID) {
        let keysToRemove = activePlaceholders.keys.filter { $0.screenId == screenId }
        for key in keysToRemove {
            if let placeholder = activePlaceholders[key] {
                closePlaceholder(placeholder, for: key, reason: .idle)
            }
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
        on descriptor: ScreenDescriptor
    )

    /// Called when a placeholder is about to be closed.
    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToClose placeholder: PlaceholderWindow,
        reason: PlaceholderCoordinator.CloseReason
    )
}

// MARK: - Context

struct PlaceholderCoordinatorScreenContext {
    let descriptor: ScreenDescriptor
    let zoneController: ZoneController
    let displayFrameForZone: (Zone) -> CGRect

    func displayFrame(for zone: Zone) -> CGRect {
        displayFrameForZone(zone)
    }
}
