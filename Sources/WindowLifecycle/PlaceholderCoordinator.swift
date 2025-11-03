import AppKit

/// Manages lifecycle and reuse of placeholder windows across zones.
final class PlaceholderCoordinator {
    enum HideReason {
        case replacedByWindow
        case idle
    }

    weak var delegate: PlaceholderCoordinatorDelegate?

    private let windowController: WindowController
    private var placeholderMappings: [Int: ZoneKey] = [:]

    init(windowController: WindowController) {
        self.windowController = windowController
    }

    /// Synchronize placeholders to match the current zone layout.
    func syncPlaceholders(
        existingWindows: [ManagedWindow],
        screenOrder: [CGDirectDisplayID],
        excludedZones: Set<ZoneKey>,
        contextProvider: (CGDirectDisplayID) -> PlaceholderCoordinatorScreenContext?
    ) {
        var placeholdersByKey: [ZoneKey: ManagedWindow] = [:]
        var unassignedPlaceholders: [ManagedWindow] = []

        for window in existingWindows where window.isPlaceholder {
            if let key = placeholderMappings[window.windowId] {
                placeholdersByKey[key] = window
            } else if let screenId = window.screenDisplayId, let zoneIndex = window.zoneIndex {
                let key = ZoneKey(screenId: screenId, index: zoneIndex)
                record(placeholder: window, key: key)
                placeholdersByKey[key] = window
            } else {
                unassignedPlaceholders.append(window)
            }
        }

        var placeholdersToRetire = placeholdersByKey

        for screenId in screenOrder {
            guard let context = contextProvider(screenId) else { continue }
            let zoneController = context.zoneController

            for zone in zoneController.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                guard zone.windowId == nil else {
                    placeholdersToRetire.removeValue(forKey: key)
                    continue
                }

                let displayFrame = context.displayFrame(for: zone)

                let isExcluded = excludedZones.contains(key)

                if let placeholder = placeholdersByKey[key] {
                    record(placeholder: placeholder, key: key)
                    delegate?.placeholderCoordinator(self, prepareToShow: placeholder, at: displayFrame, on: context.descriptor, isExcluded: isExcluded)
                    placeholdersToRetire.removeValue(forKey: key)
                } else if let reusable = unassignedPlaceholders.popLast() {
                    record(placeholder: reusable, key: key)
                    delegate?.placeholderCoordinator(self, prepareToShow: reusable, at: displayFrame, on: context.descriptor, isExcluded: isExcluded)
                } else {
                    let placeholder = windowController.createPlaceholderWindow(frame: displayFrame, zoneIndex: zone.index, on: context.descriptor)
                    record(placeholder: placeholder, key: key)
                    delegate?.placeholderCoordinator(self, prepareToShow: placeholder, at: displayFrame, on: context.descriptor, isExcluded: isExcluded)
                }
            }
        }

        for placeholder in placeholdersToRetire.values {
            delegate?.placeholderCoordinator(self, prepareToHide: placeholder, reason: .replacedByWindow)
            clearManagedZone(for: placeholder)
            forget(windowId: placeholder.windowId)
        }

        for placeholder in unassignedPlaceholders {
            delegate?.placeholderCoordinator(self, prepareToHide: placeholder, reason: .idle)
            clearManagedZone(for: placeholder)
            forget(windowId: placeholder.windowId)
        }
    }

    func record(placeholder: ManagedWindow, key: ZoneKey) {
        placeholderMappings[placeholder.windowId] = key
        windowController.refreshPlaceholderMetadata(placeholder, screenId: key.screenId, zoneIndex: key.index)
    }

    func forget(windowId: Int) {
        placeholderMappings.removeValue(forKey: windowId)
    }

    func key(for windowId: Int) -> ZoneKey? {
        placeholderMappings[windowId]
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
