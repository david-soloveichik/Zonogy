/// Manages targeted zone state and selection logic for window placement
import Foundation
import AppKit

protocol TargetedZoneManagerDelegate: AnyObject {
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    var screenOrder: [CGDirectDisplayID] { get }
    var primaryScreenId: CGDirectDisplayID { get }

    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController?
    func refreshIndicators()
}

class TargetedZoneManager {
    weak var delegate: TargetedZoneManagerDelegate?
    private(set) var targetedZoneKey: ZoneKey?

    // MARK: - Public Interface

    func initialize(primaryScreenId: CGDirectDisplayID) {
        targetedZoneKey = ZoneKey(screenId: primaryScreenId, index: 1)
    }

    func ensureTargetedZone(reason: String) {
        if let current = targetedZoneKey, zoneExists(current) {
            return
        }

        let preferredScreen = targetedZoneKey?.screenId ?? delegate?.primaryScreenId ?? 0
        let fallback = fallbackTargetedZone(preferredScreenId: preferredScreen)
        setTargetedZone(fallback, reason: reason)
    }

    func setTargetedZone(_ key: ZoneKey?, reason: String) {
        var resolvedKey = key
        if let candidate = key, !zoneExists(candidate) {
            resolvedKey = fallbackTargetedZone(preferredScreenId: candidate.screenId)
        }

        if targetedZoneKey == resolvedKey {
            delegate?.refreshIndicators()
            return
        }

        targetedZoneKey = resolvedKey

        if let resolvedKey {
            Logger.debug("Targeted zone set to \(resolvedKey.index) on display \(resolvedKey.screenId) due to \(reason)")
        } else {
            Logger.debug("Cleared targeted zone due to \(reason)")
        }

        delegate?.refreshIndicators()
    }

    func fallbackTargetedZone(preferredScreenId: CGDirectDisplayID?) -> ZoneKey? {
        let emptyCandidates = collectZoneCandidates(where: { $0.isEmpty })
        if let selection = selectLowestIndexZone(from: emptyCandidates, preferredScreenId: preferredScreenId) {
            return selection
        }

        let occupiedCandidates = collectZoneCandidates(where: { !$0.isEmpty })
        return selectHighestIndexZone(from: occupiedCandidates, preferredScreenId: preferredScreenId)
    }

    func zoneExists(_ key: ZoneKey) -> Bool {
        guard let delegate = delegate,
              let controller = delegate.zoneController(for: key.screenId) else {
            return false
        }
        return controller.zone(at: key.index) != nil
    }

    func isZoneEmpty(_ key: ZoneKey) -> Bool {
        guard let delegate = delegate,
              let controller = delegate.zoneController(for: key.screenId),
              let zone = controller.zone(at: key.index) else {
            return false
        }
        return zone.isEmpty
    }

    func lowestIndexEmptyZone(
        preferredScreenId: CGDirectDisplayID? = nil,
        excluding excluded: ZoneKey? = nil
    ) -> ZoneKey? {
        let candidates = collectZoneCandidates(where: { $0.isEmpty }, excluding: excluded)
        return selectLowestIndexZone(from: candidates, preferredScreenId: preferredScreenId)
    }

    func prefersCandidate(_ candidate: ZoneKey, over current: ZoneKey?) -> Bool {
        guard let current else {
            return true
        }

        if candidate.screenId == current.screenId {
            return candidate.index < current.index
        }

        return screenOrderIndex(for: candidate.screenId) < screenOrderIndex(for: current.screenId)
    }

    // MARK: - Private Implementation

    private func collectZoneCandidates(
        where predicate: (Zone) -> Bool,
        excluding excluded: ZoneKey? = nil
    ) -> [(ZoneKey, Int)] {
        guard let delegate = delegate else { return [] }

        var result: [(ZoneKey, Int)] = []
        for (screenId, context) in delegate.screenContexts {
            for zone in context.zoneController.allZones where predicate(zone) {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                if let excluded, excluded == key {
                    continue
                }
                result.append((key, zone.index))
            }
        }
        return result
    }

    func selectLowestIndexZone(
        from candidates: [(ZoneKey, Int)],
        preferredScreenId: CGDirectDisplayID?
    ) -> ZoneKey? {
        guard !candidates.isEmpty else {
            return nil
        }

        let minIndex = candidates.map { $0.1 }.min() ?? 0
        let lowestCandidates = candidates.filter { $0.1 == minIndex }

        if let preferredScreenId,
           let preferred = lowestCandidates.first(where: { $0.0.screenId == preferredScreenId }) {
            return preferred.0
        }

        let sorted = lowestCandidates.sorted { lhs, rhs in
            screenOrderIndex(for: lhs.0.screenId) < screenOrderIndex(for: rhs.0.screenId)
        }
        return sorted.first?.0 ?? lowestCandidates.first?.0
    }

    func selectHighestIndexZone(
        from candidates: [(ZoneKey, Int)],
        preferredScreenId: CGDirectDisplayID?
    ) -> ZoneKey? {
        guard !candidates.isEmpty else {
            return nil
        }

        let maxIndex = candidates.map { $0.1 }.max() ?? 0
        let highestCandidates = candidates.filter { $0.1 == maxIndex }

        if let preferredScreenId,
           let preferred = highestCandidates.first(where: { $0.0.screenId == preferredScreenId }) {
            return preferred.0
        }

        let sorted = highestCandidates.sorted { lhs, rhs in
            screenOrderIndex(for: lhs.0.screenId) < screenOrderIndex(for: rhs.0.screenId)
        }
        return sorted.first?.0 ?? highestCandidates.first?.0
    }

    private func screenOrderIndex(for screenId: CGDirectDisplayID) -> Int {
        delegate?.screenOrder.firstIndex(of: screenId) ?? Int.max
    }
}
