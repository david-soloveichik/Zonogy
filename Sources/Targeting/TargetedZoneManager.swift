/// Manages targeted zone state and selection logic for window placement
import Foundation
import AppKit

protocol TargetedZoneManagerDelegate: AnyObject {
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    var screenOrder: [CGDirectDisplayID] { get }
    var primaryScreenId: CGDirectDisplayID { get }
    var fullScreenDisplayIds: Set<CGDirectDisplayID> { get }

    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController?
    func refreshIndicators()
    /// Called when the targeted destination changes. Allows delegate to respond (e.g., reposition/dismiss Launcher).
    func targetedZoneDidChange(from oldDestination: TargetedZoneManager.TargetedDestination?, to newDestination: TargetedZoneManager.TargetedDestination?)
}

class TargetedZoneManager {
    enum TargetedDestination: Equatable {
        case tiled(ZoneKey)
        case floating(screenId: CGDirectDisplayID)

        /// The tiling zone this destination names, or nil for a floating zone.
        var tiledKey: ZoneKey? {
            if case .tiled(let key) = self {
                return key
            }
            return nil
        }

        /// The display this destination lives on.
        var screenId: CGDirectDisplayID {
            switch self {
            case .tiled(let key): return key.screenId
            case .floating(let screenId): return screenId
            }
        }
    }

    weak var delegate: TargetedZoneManagerDelegate?
    private(set) var targetedDestination: TargetedDestination?
    /// How a floating target was chosen. Explicit: the user pointed at the floating zone (bar
    /// click, zone navigation, the Launcher shown at it); it holds until the next retarget of any
    /// kind and is the only floating target that colors its bar. Implicit: any other rule landed
    /// the target on a floating zone; it follows the frontmost window's display silently (see
    /// `moveImplicitFloatingTarget(toDisplay:reason:)`). Always `false` for a tiling target.
    private(set) var isFloatingTargetExplicit = false

    var targetedZoneKey: ZoneKey? {
        targetedDestination?.tiledKey
    }

    var targetedFloatingScreenId: CGDirectDisplayID? {
        if case .floating(let screenId) = targetedDestination {
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
            case .tiled(let current) where zoneExists(current) && isScreenTargetable(current.screenId):
                return
            case .floating(let screenId) where screenExists(screenId) && isScreenTargetable(screenId):
                return
            default:
                break
            }
        }

        let preferredScreen: CGDirectDisplayID? = {
            switch targetedDestination {
            case .tiled(let key):
                return key.screenId
            case .floating(let screenId):
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
        if let candidate = key, !isScreenTargetable(candidate.screenId) {
            if let destination = preferredRetargetDestination(preferredSameScreenId: candidate.screenId) {
                applyRetargetDestination(destination, reason: reason)
            } else {
                setTargetedZone(nil, reason: reason)
            }
            return
        }

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
        isFloatingTargetExplicit = false

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

    /// Targets the floating zone on `screenId`. `explicit` records whether the user pointed at it
    /// (see `isFloatingTargetExplicit`); re-selecting the targeted floating zone updates that alone.
    func setFloatingTarget(on screenId: CGDirectDisplayID, reason: String, explicit: Bool = false) {
        guard screenExists(screenId) else {
            delegate?.refreshIndicators()
            return
        }

        guard isScreenTargetable(screenId) else {
            if let destination = preferredRetargetDestination(preferredSameScreenId: screenId) {
                applyRetargetDestination(destination, reason: reason)
            } else {
                setTargetedZone(nil, reason: reason)
            }
            return
        }

        let screenIndex = delegate?.screenOrder.firstIndex(of: screenId) ?? Int(screenId)
        let kind = explicit ? "explicitly" : "implicitly"
        let newDestination = TargetedDestination.floating(screenId: screenId)
        if targetedDestination == newDestination {
            if isFloatingTargetExplicit != explicit {
                isFloatingTargetExplicit = explicit
                Logger.debug("Targeted floating zone on screen \(screenIndex) now \(kind) targeted due to \(reason)")
            }
            delegate?.refreshIndicators()
            return
        }

        let oldDestination = targetedDestination
        targetedDestination = newDestination
        isFloatingTargetExplicit = explicit
        Logger.debug("Targeted floating zone set on screen \(screenIndex), \(kind), due to \(reason)")
        delegate?.refreshIndicators()
        delegate?.targetedZoneDidChange(from: oldDestination, to: newDestination)
    }

    /// Call once the Launcher has been shown at the current target: the Launcher shown at a
    /// floating zone targets it explicitly. Returns whether an implicit target became explicit.
    @discardableResult
    func markFloatingTargetExplicit(reason: String) -> Bool {
        guard case .floating(let screenId) = targetedDestination, !isFloatingTargetExplicit else { return false }
        setFloatingTarget(on: screenId, reason: reason, explicit: true)
        return true
    }

    /// An implicit floating target follows the frontmost window's display; call with that display
    /// whenever it may have changed. Explicit floating targets and tiling targets are left alone.
    func moveImplicitFloatingTarget(toDisplay screenId: CGDirectDisplayID, reason: String) {
        guard case .floating(let currentScreenId) = targetedDestination, !isFloatingTargetExplicit,
              screenId != currentScreenId, isScreenTargetable(screenId) else { return }
        setFloatingTarget(on: screenId, reason: reason)
    }

    /// When a new tiling zone is created on a screen, always target the lowest-index empty tiling zone on that screen.
    func targetAfterCreatingZone(on screenId: CGDirectDisplayID, reason: String) {
        if let empty = lowestIndexEmptyZoneOnSameScreen(screenId: screenId) {
            setTargetedZone(empty, reason: reason)
        } else {
            ensureTargetedZone(reason: reason)
        }
    }

    /// Retargets after a tiling zone is filled, per the spec's fill priority
    /// (see `preferredRetargetDestination`).
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

    /// Retargets after the floating zone on `screenId` is filled, using the same priority
    /// order as filling a tiling zone; with no empty tiling zone anywhere, the just-filled zone
    /// stays targeted, implicitly. (The Toggle Target Zone with Focused Window shortcut also
    /// routes here for a filled floating target.)
    func retargetAfterFillingFloatingZone(on screenId: CGDirectDisplayID, reason: String) {
        guard let destination = preferredRetargetDestination(preferredSameScreenId: screenId) else {
            ensureTargetedZone(reason: reason)
            return
        }
        applyRetargetDestination(destination, reason: reason)
    }

    /// Retargets as if `destination` had been targeted and just filled.
    func retargetAsIfJustFilled(_ destination: TargetedDestination, reason: String) {
        switch destination {
        case .tiled(let key):
            retargetAfterFillingZone(key, reason: reason)
        case .floating(let screenId):
            retargetAfterFillingFloatingZone(on: screenId, reason: reason)
        }
    }

    /// The move rule: moving a window from `origin` to `destination` retargets only when the
    /// move touched the target — the pre-move target was the origin or the destination. It then
    /// retargets as if the destination had been targeted and just filled (so callers should
    /// invoke this after the move settles, including any swap partner's placement). A target
    /// uninvolved in the move stays put, and a re-placement within one zone (`origin ==
    /// destination`) is not a move. A fill is a move with no origin: with `from: nil` the rule
    /// retargets exactly when the destination was the pre-move target, so placement paths use
    /// this for plain fills too.
    func retargetAfterMovingWindow(
        from origin: TargetedDestination?,
        to destination: TargetedDestination,
        preMoveTarget: TargetedDestination?,
        reason: String
    ) {
        guard let preMoveTarget,
              origin != destination,
              preMoveTarget == destination || preMoveTarget == origin else {
            return
        }
        retargetAsIfJustFilled(destination, reason: reason)
    }

    /// Shared retarget preference order for when a targeted zone is filled or removed:
    /// 1) Lowest-index empty tiling zone on the same screen
    /// 2) Lowest-index empty tiling zone on a different screen (tie-break by screen index)
    /// 3) The floating zone on the same screen, else the first floating zone in screen order
    ///    (an implicit target; see `isFloatingTargetExplicit`)
    func preferredRetargetDestination(
        preferredSameScreenId: CGDirectDisplayID?,
        excluding excluded: ZoneKey? = nil
    ) -> TargetedDestination? {
        if let preferredSameScreenId,
           isScreenTargetable(preferredSameScreenId),
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

        return floatingRetargetCandidate(preferredSameScreenId: preferredSameScreenId)
    }

    /// The floating zone an implicit target settles on: the preferred (same) screen's, else the
    /// first targetable screen's in screen order. From there it follows the frontmost window.
    private func floatingRetargetCandidate(preferredSameScreenId: CGDirectDisplayID?) -> TargetedDestination? {
        if let preferredSameScreenId, isScreenTargetable(preferredSameScreenId) {
            return .floating(screenId: preferredSameScreenId)
        }
        return delegate?.screenOrder.first(where: isScreenTargetable).map { .floating(screenId: $0) }
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
        guard isScreenTargetable(candidate.screenId) else {
            return false
        }

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
        for (screenId, context) in delegate.screenContexts where isScreenTargetable(screenId) {
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
              let context = delegate.screenContexts[screenId],
              isScreenTargetable(screenId) else {
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

    /// Whether a screen may currently hold the target. Paused (full-screen) screens are not
    /// targetable, except the fallback screen when every screen is full-screen.
    func isScreenTargetable(_ screenId: CGDirectDisplayID) -> Bool {
        guard let delegate else { return false }
        guard delegate.screenContexts[screenId] != nil else { return false }

        let fullScreenDisplayIds = delegate.fullScreenDisplayIds
        guard fullScreenDisplayIds.contains(screenId) else {
            return true
        }

        guard allScreensAreFullScreen(delegate: delegate, fullScreenDisplayIds: fullScreenDisplayIds) else {
            return false
        }

        guard let fallback = fallbackScreenId(delegate: delegate) else {
            return false
        }
        return screenId == fallback
    }

    private func allScreensAreFullScreen(
        delegate: TargetedZoneManagerDelegate,
        fullScreenDisplayIds: Set<CGDirectDisplayID>
    ) -> Bool {
        let knownScreens = Set(delegate.screenContexts.keys)
        guard !knownScreens.isEmpty else {
            return false
        }
        return knownScreens.isSubset(of: fullScreenDisplayIds)
    }

    private func fallbackScreenId(delegate: TargetedZoneManagerDelegate) -> CGDirectDisplayID? {
        let orderedFallback = delegate.screenOrder.first ?? delegate.primaryScreenId
        if delegate.screenContexts[orderedFallback] != nil {
            return orderedFallback
        }
        return delegate.screenContexts.keys.first
    }

    private func applyRetargetDestination(_ destination: TargetedDestination, reason: String) {
        switch destination {
        case .tiled(let key):
            setTargetedZone(key, reason: reason)
        case .floating(let screenId):
            setFloatingTarget(on: screenId, reason: reason)
        }
    }
}
