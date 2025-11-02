/// Drag and drop coordination for window zone assignment via mouse interaction
import Foundation
import Cocoa

struct DragSession {
    let windowId: Int
    let originZoneKey: ZoneKey?
    let originScreenId: CGDirectDisplayID?
    let originFrame: CGRect
    var latestFrame: CGRect
    var hoveredZoneKey: ZoneKey?
    let beganAt: Date
}

struct DropResult {
    let displacedWindow: ManagedWindow?
    let preferredScreenId: CGDirectDisplayID?
}

protocol DragDropCoordinatorDelegate: AnyObject {
    // Window and zone management
    var windowController: WindowController { get }
    var screenContexts: [CGDirectDisplayID: AppController.ScreenContext] { get }
    func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?)
    func clearManagedWindowZone(_ managed: ManagedWindow)
    func forgetPlaceholder(windowId: Int)
    func detectScreenId(for window: ManagedWindow) -> CGDirectDisplayID?

    // Zone management
    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController?
    func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?

    // Targeted zone management
    var targetedZoneManager: TargetedZoneManager { get }

    // Window placement
    var windowPlacementManager: WindowPlacementManager { get }

    // Synchronization
    func syncWindowsToZones(excluding excludedZones: Set<ZoneKey>)
}

class DragDropCoordinator {
    weak var delegate: DragDropCoordinatorDelegate?

    private(set) var dragSession: DragSession?
    private let dragOverlayManager = DragOverlayManager()

    init() {}

    // MARK: - Public Interface

    var isDragging: Bool {
        dragSession != nil
    }

    var currentDragWindowId: Int? {
        dragSession?.windowId
    }

    var dragExcludedZones: Set<ZoneKey> {
        guard let dragSession else {
            return []
        }
        var excluded: Set<ZoneKey> = []
        if let origin = dragSession.originZoneKey {
            excluded.insert(origin)
        }
        if let hovered = dragSession.hoveredZoneKey {
            excluded.insert(hovered)
        }
        return excluded
    }

    func beginDragSession(
        windowId: Int,
        frame: CGRect,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?
    ) {
        dragSession = DragSession(
            windowId: windowId,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            originFrame: frame,
            latestFrame: frame,
            hoveredZoneKey: nil,
            beganAt: Date()
        )
        Logger.debug("Drag session began for window \(windowId)")
        dragOverlayManager.present(over: zoneOverlayDescriptors())
        recordDragUpdate(windowId: windowId, frame: frame)
    }

    func updateDragSession(windowId: Int, frame: CGRect) {
        recordDragUpdate(windowId: windowId, frame: frame)
    }

    func endDragSession(windowId: Int, finalFrame: CGRect) -> (displacedWindow: ManagedWindow?, preferredScreenId: CGDirectDisplayID?) {
        guard let delegate = delegate else {
            tearDownDragSession()
            return (nil, nil)
        }

        recordDragUpdate(windowId: windowId, frame: finalFrame)

        guard let session = dragSession, session.windowId == windowId else {
            tearDownDragSession()
            delegate.syncWindowsToZones(excluding: [])
            return (nil, nil)
        }

        dragOverlayManager.tearDown()

        var displacedWindow: ManagedWindow?
        var displacedPreferredScreen: CGDirectDisplayID?

        if let targetKey = session.hoveredZoneKey ?? resolveDropTarget(for: finalFrame) {
            if let result = performDrop(session: session, targetKey: targetKey) {
                displacedWindow = result.displacedWindow
                displacedPreferredScreen = result.preferredScreenId
            }
        } else {
            handleDropCancellation(session: session)
        }

        dragSession = nil

        let preferredScreen = displacedPreferredScreen ?? session.originScreenId
        return (displacedWindow, preferredScreen)
    }

    func tearDownDragSession() {
        dragOverlayManager.tearDown()
        dragSession = nil
    }

    // MARK: - Private Methods

    private func zoneOverlayDescriptors() -> [ZoneOverlayDescriptor] {
        guard let delegate = delegate else { return [] }

        var descriptors: [ZoneOverlayDescriptor] = []
        for (screenId, context) in delegate.screenContexts {
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let cocoaFrame = descriptor.screenToCocoa(zone.frame)
                descriptors.append(
                    ZoneOverlayDescriptor(
                        key: ZoneKey(screenId: screenId, index: zone.index),
                        cocoaFrame: cocoaFrame,
                        isEmpty: zone.isEmpty
                    )
                )
            }
        }
        return descriptors
    }

    private func resolveDropTarget(for accessibilityFrame: CGRect) -> ZoneKey? {
        guard let delegate = delegate else { return nil }

        let normalizedFrame = accessibilityFrame.standardized
        let center = CGPoint(x: normalizedFrame.midX, y: normalizedFrame.midY)

        var bestKey: ZoneKey?
        var bestScore: CGFloat = 0
        var bestIntersection: CGFloat = 0

        for (screenId, context) in delegate.screenContexts {
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let accessibilityZone = zoneAccessibilityFrame(zone, descriptor: descriptor)
                let intersection = normalizedFrame.intersection(accessibilityZone)
                let intersectionArea: CGFloat
                if intersection.isNull {
                    intersectionArea = 0
                } else {
                    intersectionArea = intersection.width * intersection.height
                }

                let zoneArea = accessibilityZone.width * accessibilityZone.height
                let containsCenter = accessibilityZone.contains(center)
                let score = intersectionArea + (containsCenter ? zoneArea : 0)

                guard score > 0 else {
                    continue
                }

                let candidateKey = ZoneKey(screenId: screenId, index: zone.index)
                if score > bestScore ||
                    (score == bestScore && (intersectionArea > bestIntersection ||
                        (intersectionArea == bestIntersection && delegate.targetedZoneManager.prefersCandidate(candidateKey, over: bestKey)))) {
                    bestScore = score
                    bestIntersection = intersectionArea
                    bestKey = candidateKey
                }
            }
        }

        return bestKey
    }

    private func zoneAccessibilityFrame(_ zone: Zone, descriptor: ScreenDescriptor) -> CGRect {
        descriptor.screenToAccessibility(zone.frame)
    }

    private func recordDragUpdate(windowId: Int, frame: CGRect) {
        guard var session = dragSession, session.windowId == windowId else {
            return
        }
        session.latestFrame = frame
        let targetKey = resolveDropTarget(for: frame)
        session.hoveredZoneKey = targetKey
        dragSession = session
        dragOverlayManager.updateHighlight(to: targetKey)
    }

    private func handleDropCancellation(session: DragSession) {
        Logger.debug("Drag cancelled for window \(session.windowId); reverting to original assignment if needed")
    }

    private func performDrop(session: DragSession, targetKey: ZoneKey) -> DropResult? {
        guard let delegate = delegate,
              let managed = delegate.windowController.window(withId: session.windowId) else {
            return nil
        }

        guard let targetContext = delegate.screenContexts[targetKey.screenId],
              let targetZone = targetContext.zoneController.zone(at: targetKey.index) else {
            return nil
        }

        if targetZone.windowId == session.windowId {
            Logger.debug("Window \(session.windowId) already assigned to target zone \(targetKey.index); no swap needed")
            delegate.setManagedWindow(managed, screenId: targetKey.screenId, zoneIndex: targetKey.index)
            return DropResult(displacedWindow: nil, preferredScreenId: nil)
        }

        let sourceKey = session.originZoneKey

        if let sourceKey,
           sourceKey == targetKey {
            Logger.debug("Window \(session.windowId) dropped back into its original zone \(targetKey.index)")
            return DropResult(displacedWindow: nil, preferredScreenId: nil)
        }

        if let sourceKey,
           let sourceContext = delegate.screenContexts[sourceKey.screenId] {
            sourceContext.zoneController.removeWindow(windowId: session.windowId)
        }

        var displacedWindow: ManagedWindow?
        if let displacedWindowId = targetZone.windowId,
           displacedWindowId != session.windowId,
           let occupant = delegate.windowController.window(withId: displacedWindowId) {
            targetContext.zoneController.removeWindow(windowId: displacedWindowId)
            displacedWindow = occupant
        }

        targetContext.zoneController.assignWindow(windowId: session.windowId, toZoneIndex: targetKey.index)
        delegate.setManagedWindow(managed, screenId: targetKey.screenId, zoneIndex: targetKey.index)
        Logger.debug("Window \(session.windowId) dropped into zone \(targetKey.index) on \(targetContext.descriptor.localizedName)")

        if let sourceKey,
           let sourceContext = delegate.screenContexts[sourceKey.screenId],
           let displaced = displacedWindow {
            sourceContext.zoneController.assignWindow(windowId: displaced.windowId, toZoneIndex: sourceKey.index)
            delegate.setManagedWindow(displaced, screenId: sourceKey.screenId, zoneIndex: sourceKey.index)
            Logger.debug("Swapped displaced window \(displaced.windowId) back into original zone \(sourceKey.index)")
            return DropResult(displacedWindow: nil, preferredScreenId: nil)
        }

        if let displaced = displacedWindow {
            if displaced.isPlaceholder {
                Logger.debug("Closing displaced placeholder \(displaced.windowId) after drop")
                delegate.windowController.closeWindow(displaced)
                delegate.forgetPlaceholder(windowId: displaced.windowId)
                return DropResult(displacedWindow: nil, preferredScreenId: nil)
            }
            delegate.clearManagedWindowZone(displaced)
            Logger.debug("Window \(displaced.windowId) displaced from zone \(targetKey.index); will reassign later")
            return DropResult(displacedWindow: displaced, preferredScreenId: targetKey.screenId)
        }

        return DropResult(displacedWindow: nil, preferredScreenId: nil)
    }
}