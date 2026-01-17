/// Manages targeted zone state and selection logic for window placement
import Foundation
import AppKit

protocol TargetedZoneManagerDelegate: AnyObject {
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    var screenOrder: [CGDirectDisplayID] { get }
    var primaryScreenId: CGDirectDisplayID { get }

    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController?
    func refreshIndicators()
    /// Called when the targeted destination changes. Allows delegate to respond (e.g., reposition/dismiss Launcher).
    func targetedZoneDidChange(from oldDestination: TargetedZoneManager.TargetedDestination?, to newDestination: TargetedZoneManager.TargetedDestination?)
}

class TargetedZoneManager {
    enum TargetedDestination: Equatable {
        case tiled(ZoneKey)
        case temporary(screenId: CGDirectDisplayID)
    }

    weak var delegate: TargetedZoneManagerDelegate?
    private(set) var targetedDestination: TargetedDestination?

    var targetedZoneKey: ZoneKey? {
        if case .tiled(let key) = targetedDestination {
            return key
        }
        return nil
    }

    var targetedTemporaryScreenId: CGDirectDisplayID? {
        if case .temporary(let screenId) = targetedDestination {
            return screenId
        }
        return nil
    }

    // MARK: - Public Interface

    func initialize(primaryScreenId: CGDirectDisplayID) {
        targetedDestination = .tiled(ZoneKey(screenId: primaryScreenId, index: 1))
    }

    func ensureTargetedZone(reason: String) {
        if let destination = targetedDestination {
            switch destination {
            case .tiled(let current) where zoneExists(current):
                return
            case .temporary(let screenId) where screenExists(screenId):
                return
            default:
                break
            }
        }

        let preferredScreen: CGDirectDisplayID? = {
            switch targetedDestination {
            case .tiled(let key):
                return key.screenId
            case .temporary(let screenId):
                return screenId
            case nil:
                return delegate?.primaryScreenId
            }
        }()

        guard let destination = preferredRetargetDestination(preferredSameScreenId: preferredScreen) else {
            setTargetedZone(nil, reason: reason)
            return
        }
        applyRetargetDestination(destination, reason: reason)
    }

    func setTargetedZone(_ key: ZoneKey?, reason: String) {
        if let candidate = key, !zoneExists(candidate) {
            if let destination = preferredRetargetDestination(preferredSameScreenId: candidate.screenId) {
                applyRetargetDestination(destination, reason: reason)
            } else {
                setTargetedZone(nil, reason: reason)
            }
            return
        }

        let newDestination = key.map { TargetedDestination.tiled($0) }
        if let key,
           targetedDestination == .tiled(key) {
            delegate?.refreshIndicators()
            return
        }

        let oldDestination = targetedDestination
        targetedDestination = newDestination

        if let key {
            // Convert display ID to a user-facing index for logging, using current screen ordering.
            let screenIndex = delegate?.screenOrder.firstIndex(of: key.screenId) ?? Int(key.screenId)
            Logger.debug("Targeted zone set to \(key.index) on screen \(screenIndex) due to \(reason)")
        } else {
            Logger.debug("Cleared targeted zone due to \(reason)")
        }

        delegate?.refreshIndicators()
        delegate?.targetedZoneDidChange(from: oldDestination, to: newDestination)
    }

    func setTemporaryTarget(on screenId: CGDirectDisplayID, reason: String) {
        guard screenExists(screenId) else {
            delegate?.refreshIndicators()
            return
        }

        let newDestination = TargetedDestination.temporary(screenId: screenId)
        if targetedDestination == newDestination {
            delegate?.refreshIndicators()
            return
        }

        let oldDestination = targetedDestination
        targetedDestination = newDestination
        let screenIndex = delegate?.screenOrder.firstIndex(of: screenId) ?? Int(screenId)
        Logger.debug("Targeted temporary zone set on screen \(screenIndex) due to \(reason)")
        delegate?.refreshIndicators()
        delegate?.targetedZoneDidChange(from: oldDestination, to: newDestination)
    }

    /// Retargets after a zone is filled, per spec: "if another empty normal zone exists
    /// on the same screen, retarget to such zone with the lowest index; if none exist,
    /// retarget to the lowest-index empty tiling zone on another screen; if none exist,
    /// target the temporary zone (same screen preferred)."
    func retargetAfterFillingZone(_ filledKey: ZoneKey, reason: String) {
        guard let destination = preferredRetargetDestination(
            preferredSameScreenId: filledKey.screenId,
            excluding: filledKey
        ) else {
            setTargetedZone(nil, reason: reason)
            return
        }
        applyRetargetDestination(destination, reason: reason)
    }

    /// Shared retarget preference order for when a targeted empty tiling zone is filled or a targeted
    /// tiling zone is removed:
    /// 1) Lowest-index empty tiling zone on the same screen
    /// 2) Lowest-index empty tiling zone on a different screen (tie-break by screen index)
    /// 3) Temporary zone on the same screen
    /// 4) Temporary zone on a different screen (tie-break by screen index)
    func preferredRetargetDestination(
        preferredSameScreenId: CGDirectDisplayID?,
        excluding excluded: ZoneKey? = nil
    ) -> TargetedDestination? {
        if let preferredSameScreenId,
           let sameScreenEmpty = lowestIndexEmptyZoneOnSameScreen(screenId: preferredSameScreenId, excluding: excluded) {
            return .tiled(sameScreenEmpty)
        }

        let allEmpty = collectZoneCandidates(where: { $0.isEmpty }, excluding: excluded)
        let otherScreenEmpty = allEmpty.filter { candidate, _ in
            guard let preferredSameScreenId else { return true }
            return candidate.screenId != preferredSameScreenId
        }
        if let selection = selectLowestIndexZone(from: otherScreenEmpty, preferredScreenId: nil) {
            return .tiled(selection)
        }

        if let preferredSameScreenId,
           screenExists(preferredSameScreenId) {
            return .temporary(screenId: preferredSameScreenId)
        }

        guard let delegate else { return nil }
        for screenId in delegate.screenOrder {
            if let preferredSameScreenId, screenId == preferredSameScreenId {
                continue
            }
            if screenExists(screenId) {
                return .temporary(screenId: screenId)
            }
        }
        return nil
    }

    func zoneExists(_ key: ZoneKey) -> Bool {
        guard let delegate = delegate,
              let controller = delegate.zoneController(for: key.screenId) else {
            return false
        }
        return controller.zone(at: key.index) != nil
    }

    private func screenExists(_ screenId: CGDirectDisplayID) -> Bool {
        delegate?.screenContexts[screenId] != nil
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

    /// Find the lowest-index empty zone on the same screen only
    func lowestIndexEmptyZoneOnSameScreen(
        screenId: CGDirectDisplayID,
        excluding excluded: ZoneKey? = nil
    ) -> ZoneKey? {
        let candidates = collectZoneCandidatesOnScreen(screenId: screenId, where: { $0.isEmpty }, excluding: excluded)
        guard !candidates.isEmpty else {
            return nil
        }

        let minIndex = candidates.map { $0.1 }.min() ?? 0
        return candidates.first(where: { $0.1 == minIndex })?.0
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

    private func collectZoneCandidatesOnScreen(
        screenId: CGDirectDisplayID,
        where predicate: (Zone) -> Bool,
        excluding excluded: ZoneKey? = nil
    ) -> [(ZoneKey, Int)] {
        guard let delegate = delegate,
              let context = delegate.screenContexts[screenId] else {
            return []
        }

        var result: [(ZoneKey, Int)] = []
        for zone in context.zoneController.allZones where predicate(zone) {
            let key = ZoneKey(screenId: screenId, index: zone.index)
            if let excluded, excluded == key {
                continue
            }
            result.append((key, zone.index))
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

    private func applyRetargetDestination(_ destination: TargetedDestination, reason: String) {
        switch destination {
        case .tiled(let key):
            setTargetedZone(key, reason: reason)
        case .temporary(let screenId):
            setTemporaryTarget(on: screenId, reason: reason)
        }
    }
}
