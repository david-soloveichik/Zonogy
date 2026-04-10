/// Drag and drop coordination for window zone assignment via mouse interaction
import Foundation
import Cocoa

struct DragSession {
    let windowId: Int?  // nil for non-running app drags
    let originZoneKey: ZoneKey?
    let originScreenId: CGDirectDisplayID?
    let originFrame: CGRect
    var latestFrame: CGRect
    var hoveredZoneKey: ZoneKey?
    var hoveredAddZoneScreenId: CGDirectDisplayID?
    var hoveredFloatingScreenId: CGDirectDisplayID?
    let originatedFromFloating: Bool
    let isCursorDriven: Bool  // true for DockMenu drags (no actual window frame updates)
    let beganAt: Date
}

enum DisplacedWindowDisposition {
    case reassign
    case minimize
}

struct DropResult {
    let displacedWindow: ManagedWindow?
    let preferredScreenId: CGDirectDisplayID?
    let displacedDisposition: DisplacedWindowDisposition

    init(
        displacedWindow: ManagedWindow?,
        preferredScreenId: CGDirectDisplayID?,
        displacedDisposition: DisplacedWindowDisposition = .reassign
    ) {
        self.displacedWindow = displacedWindow
        self.preferredScreenId = preferredScreenId
        self.displacedDisposition = displacedDisposition
    }
}

struct EndDragSessionResult {
    let displacedWindow: ManagedWindow?
    let preferredScreenId: CGDirectDisplayID?
    let displacedDisposition: DisplacedWindowDisposition
    let originatedFromFloating: Bool
    let didResolveDrop: Bool
}

protocol DragDropCoordinatorDelegate: AnyObject {
    // Window and zone management
    var windowController: WindowController { get }
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    func clearRememberedManualResizeSize(for windowId: Int, reason: String) -> CGSize?
    func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?)
    func clearManagedWindowZone(_ managed: ManagedWindow)
    func detectScreenId(for window: ManagedWindow) -> CGDirectDisplayID?

    // Zone management
    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController?
    func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?

    // Targeted zone management
    var targetedZoneManager: TargetedZoneManager { get }

    // Window placement
    var windowPlacementManager: WindowPlacementManager { get }

    // Synchronization
    func syncWindowsToZones(recentlyPlacedInFloatingZone: Int?)

    // Full-screen handling
    func isScreenPausedForFullScreen(_ screenId: CGDirectDisplayID) -> Bool

    // Add-zone indicator support
    func addZoneIndicatorHitAreas() -> [CGDirectDisplayID: CGRect]
    func updateAddZoneIndicatorHighlight(screenId: CGDirectDisplayID?)
    func floatingIndicatorHitAreas() -> [CGDirectDisplayID: CGRect]
    func updateFloatingIndicatorHighlight(screenId: CGDirectDisplayID?)
    @discardableResult
    func addZone(on screenId: CGDirectDisplayID, announce: Bool, promoteFloatingOccupant: Bool) -> Zone?

    // Floating zone placement
    func dropWindowIntoFloatingZone(_ managed: ManagedWindow, from originKey: ZoneKey?, on screenId: CGDirectDisplayID)
    var isControlCommandModifierHeld: Bool { get }
    func resumeFloatingDrag(windowId: Int, frame: CGRect, originScreenId: CGDirectDisplayID?)
    func promoteTiledDragToFloating(
        windowId: Int,
        frame: CGRect,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?,
        preferredFloatingScreenId: CGDirectDisplayID?
    ) -> Bool
}

class DragDropCoordinator {
    weak var delegate: DragDropCoordinatorDelegate?

    private(set) var dragSession: DragSession?
    private let dragOverlayManager = DragOverlayManager()
    private var cursorPointOverrideAX: CGPoint?

    init() {}

    // MARK: - Public Interface

    var isDragging: Bool {
        dragSession != nil
    }

    var currentDragWindowId: Int? {
        dragSession?.windowId
    }

    func beginDragSession(
        windowId: Int,
        frame: CGRect,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?,
        originatedFromFloating: Bool = false
    ) {
        cursorPointOverrideAX = nil
        dragSession = DragSession(
            windowId: windowId,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            originFrame: frame,
            latestFrame: frame,
            hoveredZoneKey: nil,
            hoveredAddZoneScreenId: nil,
            hoveredFloatingScreenId: nil,
            originatedFromFloating: originatedFromFloating,
            isCursorDriven: false,
            beganAt: Date()
        )
        Logger.debug("Drag session began for window \(windowId)")
        dragOverlayManager.present(over: zoneOverlayDescriptors())
        recordDragUpdate(windowId: windowId, frame: frame)
    }

    /// Begins a cursor-driven drag session (for DockMenu drags where no actual window is being dragged).
    /// Updates are driven by cursor position rather than window frame changes.
    func beginCursorDrivenDragSession(
        windowId: Int?,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?,
        originatedFromFloating: Bool = false
    ) {
        cursorPointOverrideAX = nil
        let cursorFrame = cursorSyntheticFrame()
        dragSession = DragSession(
            windowId: windowId,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            originFrame: cursorFrame,
            latestFrame: cursorFrame,
            hoveredZoneKey: nil,
            hoveredAddZoneScreenId: nil,
            hoveredFloatingScreenId: nil,
            originatedFromFloating: originatedFromFloating,
            isCursorDriven: true,
            beganAt: Date()
        )
        if let windowId {
            Logger.debug("Cursor-driven drag session began for window \(windowId)")
        } else {
            Logger.debug("Cursor-driven drag session began (no window)")
        }
        dragOverlayManager.present(over: zoneOverlayDescriptors())
        updateCursorDrivenDragSession()
    }

    /// Updates a cursor-driven drag session using current cursor position.
    func updateCursorDrivenDragSession(cursorPointAX: CGPoint? = nil) {
        guard let session = dragSession, session.isCursorDriven else { return }
        if let cursorPointAX {
            cursorPointOverrideAX = cursorPointAX
        }
        let cursorFrame = cursorSyntheticFrame()
        recordDragUpdate(windowId: session.windowId, frame: cursorFrame)
    }

    /// Resolved drop target for cursor-driven drags
    enum CursorDrivenDropTarget {
        case tilingZone(ZoneKey)
        case floatingZone(CGDirectDisplayID)
        case addZone(CGDirectDisplayID)
        case cancelled
    }

    /// Ends a cursor-driven drag session by resolving the drop target and tearing down overlays.
    /// Returns the resolved drop target; the caller is responsible for performing the actual placement.
    func endCursorDrivenDragSession(cursorPointAX: CGPoint? = nil) -> CursorDrivenDropTarget {
        if let cursorPointAX {
            cursorPointOverrideAX = cursorPointAX
        }
        guard let session = dragSession, session.isCursorDriven else {
            tearDownDragSession()
            return .cancelled
        }

        dragOverlayManager.tearDown()

        guard let cursorPoint = currentCursorAccessibilityPoint() else {
            Logger.debug("Cursor-driven drag aborted: unable to resolve cursor position")
            dragSession = nil
            cursorPointOverrideAX = nil
            delegate?.updateAddZoneIndicatorHighlight(screenId: nil)
            delegate?.updateFloatingIndicatorHighlight(screenId: nil)
            return .cancelled
        }

        let target: CursorDrivenDropTarget
        if let addZoneScreenId = session.hoveredAddZoneScreenId ?? resolveAddZoneDropTarget(cursorPoint: cursorPoint) {
            target = .addZone(addZoneScreenId)
        } else if let floatingScreenId = session.hoveredFloatingScreenId ?? resolveFloatingDropTarget(cursorPoint: cursorPoint) {
            target = .floatingZone(floatingScreenId)
        } else if let targetKey = session.hoveredZoneKey ?? resolveDropTarget(for: cursorSyntheticFrame(), cursorPoint: cursorPoint) {
            target = .tilingZone(targetKey)
        } else {
            target = .cancelled
        }

        dragSession = nil
        cursorPointOverrideAX = nil
        delegate?.updateAddZoneIndicatorHighlight(screenId: nil)
        delegate?.updateFloatingIndicatorHighlight(screenId: nil)

        Logger.debug("Cursor-driven drag ended with target: \(target)")
        return target
    }

    /// Creates a synthetic 1x1 frame at the current cursor position (in accessibility coordinates).
    private func cursorSyntheticFrame() -> CGRect {
        if let point = currentCursorAccessibilityPoint() {
            return CGRect(origin: point, size: CGSize(width: 1, height: 1))
        }
        return .zero
    }

    func updateDragSession(windowId: Int, frame: CGRect) {
        recordDragUpdate(windowId: windowId, frame: frame)
    }

    func endDragSession(windowId: Int, finalFrame: CGRect) -> EndDragSessionResult {
        cursorPointOverrideAX = nil
        guard let delegate = delegate else {
            tearDownDragSession()
            return EndDragSessionResult(
                displacedWindow: nil,
                preferredScreenId: nil,
                displacedDisposition: .reassign,
                originatedFromFloating: false,
                didResolveDrop: false
            )
        }

        recordDragUpdate(windowId: windowId, frame: finalFrame)

        guard let session = dragSession, session.windowId == windowId else {
            tearDownDragSession()
            delegate.syncWindowsToZones(recentlyPlacedInFloatingZone: nil)
            return EndDragSessionResult(
                displacedWindow: nil,
                preferredScreenId: nil,
                displacedDisposition: .reassign,
                originatedFromFloating: false,
                didResolveDrop: false
            )
        }

        dragOverlayManager.tearDown()

        var displacedWindow: ManagedWindow?
        var displacedPreferredScreen: CGDirectDisplayID?
        var displacedDisposition: DisplacedWindowDisposition = .reassign
        var didResolveDrop = false
        guard let cursorPoint = currentCursorAccessibilityPoint() else {
            Logger.debug("Drag drop aborted: unable to resolve cursor position")
            handleDropCancellation(session: session)
            dragSession = nil
            delegate.updateAddZoneIndicatorHighlight(screenId: nil)
            delegate.updateFloatingIndicatorHighlight(screenId: nil)
            return EndDragSessionResult(
                displacedWindow: nil,
                preferredScreenId: session.originScreenId,
                displacedDisposition: .reassign,
                originatedFromFloating: session.originatedFromFloating,
                didResolveDrop: false
            )
        }

        if let addZoneScreenId = session.hoveredAddZoneScreenId ?? resolveAddZoneDropTarget(cursorPoint: cursorPoint) {
            if let result = performDropIntoNewZone(session: session, screenId: addZoneScreenId) {
                displacedWindow = result.displacedWindow
                displacedPreferredScreen = result.preferredScreenId
                displacedDisposition = result.displacedDisposition
                didResolveDrop = true
            } else {
                handleDropCancellation(session: session)
            }
        } else if let floatingScreenId = session.hoveredFloatingScreenId ?? resolveFloatingDropTarget(cursorPoint: cursorPoint) {
            if let result = performDropIntoFloatingZone(session: session, screenId: floatingScreenId) {
                displacedWindow = result.displacedWindow
                displacedPreferredScreen = result.preferredScreenId
                displacedDisposition = result.displacedDisposition
                didResolveDrop = true
            } else {
                handleDropCancellation(session: session)
            }
        } else if let targetKey = session.hoveredZoneKey ?? resolveDropTarget(for: finalFrame, cursorPoint: cursorPoint) {
            // Control-Command floating drags skip empty zones as drop targets
            if session.originatedFromFloating,
               let context = delegate.screenContexts[targetKey.screenId],
               let zone = context.zoneController.zone(at: targetKey.index),
               zone.isEmpty {
                handleDropCancellation(session: session)
            } else if let result = performDrop(session: session, targetKey: targetKey) {
                displacedWindow = result.displacedWindow
                displacedPreferredScreen = result.preferredScreenId
                displacedDisposition = result.displacedDisposition
                didResolveDrop = true
            }
        } else {
            handleDropCancellation(session: session)
        }

        dragSession = nil
        cursorPointOverrideAX = nil
        delegate.updateAddZoneIndicatorHighlight(screenId: nil)
        delegate.updateFloatingIndicatorHighlight(screenId: nil)

        let preferredScreen = displacedPreferredScreen ?? session.originScreenId
        return EndDragSessionResult(
            displacedWindow: displacedWindow,
            preferredScreenId: preferredScreen,
            displacedDisposition: displacedDisposition,
            originatedFromFloating: session.originatedFromFloating,
            didResolveDrop: didResolveDrop
        )
    }

    func tearDownDragSession() {
        dragOverlayManager.tearDown()
        dragSession = nil
        cursorPointOverrideAX = nil
        delegate?.updateAddZoneIndicatorHighlight(screenId: nil)
        delegate?.updateFloatingIndicatorHighlight(screenId: nil)
    }

    // MARK: - Private Methods

    private func zoneOverlayDescriptors() -> [ZoneOverlayDescriptor] {
        guard let delegate = delegate else { return [] }

        var descriptors: [ZoneOverlayDescriptor] = []
        for (screenId, context) in delegate.screenContexts {
            if delegate.isScreenPausedForFullScreen(screenId) {
                continue
            }
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

    private func resolveDropTarget(for accessibilityFrame: CGRect, cursorPoint: CGPoint?) -> ZoneKey? {
        guard let cursorPoint,
              let delegate = delegate else {
            return nil
        }

        for (screenId, context) in delegate.screenContexts {
            if delegate.isScreenPausedForFullScreen(screenId) {
                continue
            }
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let accessibilityZone = zoneAccessibilityFrame(zone, descriptor: descriptor)
                let candidateKey = ZoneKey(screenId: screenId, index: zone.index)

                if accessibilityZone.contains(cursorPoint) {
                    return candidateKey
                }
            }
        }

        return nil
    }

    private func zoneAccessibilityFrame(_ zone: Zone, descriptor: ScreenDescriptor) -> CGRect {
        descriptor.screenToAccessibility(zone.frame)
    }

    private func resolveAddZoneDropTarget(cursorPoint: CGPoint?) -> CGDirectDisplayID? {
        guard let cursorPoint,
              let delegate = delegate else {
            return nil
        }
        let hitAreas = delegate.addZoneIndicatorHitAreas()
        for (screenId, frame) in hitAreas where frame.contains(cursorPoint) {
            return screenId
        }
        return nil
    }

    private func resolveFloatingDropTarget(cursorPoint: CGPoint?) -> CGDirectDisplayID? {
        guard let cursorPoint,
              let delegate = delegate else {
            return nil
        }

        let hitAreas = delegate.floatingIndicatorHitAreas()
        if let targeted = delegate.targetedZoneManager.targetedFloatingScreenId,
           let targetedFrame = hitAreas[targeted], targetedFrame.contains(cursorPoint) {
            return targeted
        }

        for (screenId, frame) in hitAreas where frame.contains(cursorPoint) {
            return screenId
        }
        return nil
    }

    private func recordDragUpdate(windowId: Int?, frame: CGRect) {
        guard var session = dragSession, session.windowId == windowId else {
            return
        }
        // Floating drag resumption only applies when there's a real window
        if let windowId, session.originatedFromFloating,
           let delegate = delegate,
           !delegate.isControlCommandModifierHeld {
            dragOverlayManager.tearDown()
            dragSession = nil
            cursorPointOverrideAX = nil
            delegate.resumeFloatingDrag(windowId: windowId, frame: frame, originScreenId: session.originScreenId)
            return
        }
        session.latestFrame = frame
        let cursorPoint = currentCursorAccessibilityPoint()
        let addZoneScreenId = resolveAddZoneDropTarget(cursorPoint: cursorPoint)
        var targetKey: ZoneKey?
        if addZoneScreenId == nil {
            targetKey = resolveDropTarget(for: frame, cursorPoint: cursorPoint)
        }
        // Control-Command floating drags skip empty zones as drop targets
        if session.originatedFromFloating, let key = targetKey {
            if let context = delegate?.screenContexts[key.screenId],
               let zone = context.zoneController.zone(at: key.index),
               zone.isEmpty {
                targetKey = nil
            }
        }
        var floatingScreenId: CGDirectDisplayID?
        if addZoneScreenId == nil {
            floatingScreenId = resolveFloatingDropTarget(cursorPoint: cursorPoint)
        }
        // Tiled-to-floating promotion only applies when there's a real window
        if let windowId, !session.originatedFromFloating,
           let delegate,
           delegate.isControlCommandModifierHeld {
            // Clear drag session BEFORE promotion so any follow-up sync runs without stale drag state.
            let preferredFloatingScreenId = floatingScreenId
                ?? session.hoveredFloatingScreenId
                ?? delegate.targetedZoneManager.targetedFloatingScreenId
            dragOverlayManager.tearDown()
            dragSession = nil
            cursorPointOverrideAX = nil
            delegate.updateAddZoneIndicatorHighlight(screenId: nil)
            delegate.updateFloatingIndicatorHighlight(screenId: nil)

            let promoted = delegate.promoteTiledDragToFloating(
                windowId: windowId,
                frame: frame,
                originZoneKey: session.originZoneKey,
                originScreenId: session.originScreenId,
                preferredFloatingScreenId: preferredFloatingScreenId
            )
            if !promoted {
                Logger.debug("Control-Command drag promotion failed for window \(windowId)")
            }
            return
        }
        session.hoveredZoneKey = targetKey
        session.hoveredAddZoneScreenId = addZoneScreenId
        session.hoveredFloatingScreenId = floatingScreenId
        dragSession = session
        dragOverlayManager.updateHighlight(to: targetKey)
        delegate?.updateAddZoneIndicatorHighlight(screenId: addZoneScreenId)
        delegate?.updateFloatingIndicatorHighlight(screenId: floatingScreenId)
    }

    private func currentCursorAccessibilityPoint() -> CGPoint? {
        if let cursorPointOverrideAX {
            return cursorPointOverrideAX
        }
        guard let delegate = delegate else {
            return nil
        }
        let cocoaLocation = NSEvent.mouseLocation
        let cocoaPoint = CGPoint(x: cocoaLocation.x, y: cocoaLocation.y)
        let cocoaFrame = CGRect(origin: cocoaPoint, size: .zero)
        let accessibilityFrame = CoordinateConversion.cocoaToAccessibility(
            cocoaFrame: cocoaFrame,
            primaryScreenBounds: delegate.windowController.primaryScreenBounds
        )
        return accessibilityFrame.origin
    }

    private func handleDropCancellation(session: DragSession) {
        if let windowId = session.windowId {
            Logger.debug("Drag cancelled for window \(windowId); reverting to original assignment if needed")
        } else {
            Logger.debug("Drag cancelled (no window); no reversion needed")
        }
    }

    private func performDropIntoNewZone(session: DragSession, screenId: CGDirectDisplayID) -> DropResult? {
        guard let delegate = delegate else {
            return nil
        }
        guard let newZone = delegate.addZone(on: screenId, announce: false, promoteFloatingOccupant: false) else {
            Logger.debug("Failed to add zone on \(ScreenContextStore.logDescription(for: screenId)) for drag-drop request")
            return nil
        }
        let newKey = ZoneKey(screenId: screenId, index: newZone.index)
        return performDrop(session: session, targetKey: newKey)
    }

    private func performDropIntoFloatingZone(session: DragSession, screenId: CGDirectDisplayID) -> DropResult? {
        guard let delegate = delegate,
              let windowId = session.windowId,
              let managed = delegate.windowController.window(withId: windowId) else {
            return nil
        }

        delegate.dropWindowIntoFloatingZone(managed, from: session.originZoneKey, on: screenId)
        return DropResult(displacedWindow: nil, preferredScreenId: screenId)
    }

    private func performDrop(session: DragSession, targetKey: ZoneKey) -> DropResult? {
        guard let delegate = delegate,
              let windowId = session.windowId,
              let managed = delegate.windowController.window(withId: windowId) else {
            return nil
        }

        guard let targetContext = delegate.screenContexts[targetKey.screenId],
              let targetZone = targetContext.zoneController.zone(at: targetKey.index) else {
            return nil
        }

        let sourceKey = session.originZoneKey

        if targetZone.occupantWindowId == windowId {
            _ = delegate.clearRememberedManualResizeSize(
                for: windowId,
                reason: "drag-drop-same-tiling-zone"
            )
            Logger.debug("Window \(windowId) already assigned to target zone \(targetKey.index); no swap needed")
            delegate.setManagedWindow(managed, screenId: targetKey.screenId, zoneIndex: targetKey.index)
            return DropResult(displacedWindow: nil, preferredScreenId: nil)
        }

        if let sourceKey,
           sourceKey == targetKey {
            _ = delegate.clearRememberedManualResizeSize(
                for: windowId,
                reason: "drag-drop-same-tiling-zone"
            )
            Logger.debug("Window \(windowId) dropped back into its original zone \(targetKey.index)")
            return DropResult(displacedWindow: nil, preferredScreenId: nil)
        }

        if let sourceKey,
           let sourceContext = delegate.screenContexts[sourceKey.screenId] {
            sourceContext.zoneController.removeWindow(windowId: windowId)
        }

        guard let assignment = delegate.windowPlacementManager.assignWindowFromDrag(managed, to: targetKey) else {
            Logger.debug("Drag drop failed: unable to assign window \(windowId) to zone \(targetKey.index) on screen \(targetContext.descriptor.localizedName)")
            return nil
        }

        let displacedWindow = assignment.displacedWindow
        Logger.debug("Window \(windowId) dropped into zone \(targetKey.index) on \(targetContext.descriptor.localizedName)")

        if let sourceKey,
           let sourceContext = delegate.screenContexts[sourceKey.screenId],
           let displaced = displacedWindow {
            sourceContext.zoneController.assignWindow(windowId: displaced.windowId, toZoneIndex: sourceKey.index)
            delegate.setManagedWindow(displaced, screenId: sourceKey.screenId, zoneIndex: sourceKey.index)
            Logger.debug("Swapped displaced window \(displaced.windowId) back into original zone \(sourceKey.index)")
            return DropResult(displacedWindow: nil, preferredScreenId: nil)
        }

        if let displaced = displacedWindow {
            Logger.debug("Window \(displaced.windowId) displaced from zone \(targetKey.index); will reassign later")
            return DropResult(
                displacedWindow: displaced,
                preferredScreenId: targetKey.screenId,
                displacedDisposition: session.originatedFromFloating ? .minimize : .reassign
            )
        }

        return DropResult(displacedWindow: nil, preferredScreenId: nil)
    }
}
