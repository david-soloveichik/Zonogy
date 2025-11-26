/// Primary coordination hub for zone management, window placement, and system integration
import Foundation
import AppKit
import ApplicationServices

class AppController: NSObject, WindowControllerDelegate, ZoneIndicatorManagerDelegate, ZoneResizeHandleManagerDelegate, TemporaryZoneIndicatorManagerDelegate, AddZoneIndicatorManagerDelegate, ValidationRetryManagerDelegate, TargetedZoneManagerDelegate, WindowPlacementManagerDelegate, DragDropCoordinatorDelegate, HotkeyServiceDelegate, SystemEventMonitorDelegate, WindowCapturePipelineDelegate, PlaceholderCoordinatorDelegate, DisplayReconfigurationMonitorDelegate, ZoneClickInterceptorDelegate, MenuBarManagerDelegate, TemporaryZoneCoordinatorHost, TemporaryDragHandlerHost, DisplacedWindowCoordinatorHost {
    enum SuppressedEvent: String {
        case miniaturized
    }
    struct FloatingTemporaryDragState {
        let windowId: Int
        var hoveredAddZoneScreenId: CGDirectDisplayID?
        var hoveredTemporaryScreenId: CGDirectDisplayID?
    }
    struct ZoneEdgeMargins {
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat
    }
    struct TiledToTemporaryDragContext {
        let originZoneKey: ZoneKey?
        let originScreenId: CGDirectDisplayID?
        let temporaryScreenId: CGDirectDisplayID
        let displacedWindowId: Int?
        let displacedWindowFrame: CGRect?
    }

    struct TemporaryZoneIdentitySnapshot {
        let screenId: CGDirectDisplayID
        let identity: WindowIdentity
    }

    static let shared = AppController()

    internal let windowController: WindowController
    internal let configuration: Configuration
    internal let validationRetryManager = ValidationRetryManager()
    internal let targetedZoneManager = TargetedZoneManager()
    internal let windowPlacementManager = WindowPlacementManager()
    internal let browserLaunchController = BrowserLaunchController()
    internal let dragDropCoordinator = DragDropCoordinator()
    internal let screenContextStore: ScreenContextStore
    internal let hotkeyService = HotkeyService()
    internal let systemEventMonitor = SystemEventMonitor()
    internal let displayMonitor = DisplayReconfigurationMonitor()
    internal let zoneClickInterceptor = ZoneClickInterceptor()
    let primaryScreenId: CGDirectDisplayID  // Internal tracking uses stable CGDirectDisplayID
    internal let primaryScreenBounds: CGRect
    internal let zoneMargin: CGFloat = 8
    internal let edgeAlignmentTolerance: CGFloat = 0.5
    internal var isSyncingWindows = false
    internal var pendingSync = false
    internal var pendingSyncExcludedZones: Set<ZoneKey> = []
    internal var liveResizingZoneKey: ZoneKey?
    /// True while the user is actively dragging a zone separator (live zone resize).
    /// Used to temporarily suppress ActiveFit and AX frame retries during the gesture.
    internal var zoneResizeDragInProgress = false
    internal var isZoneResizeInProgress = false
    internal var lastActiveApplicationPid: pid_t?
    internal let capturePipeline: WindowCapturePipeline
    internal let placeholderCoordinator: PlaceholderCoordinator
    internal let indicatorManager = ZoneIndicatorManager()
    internal let temporaryIndicatorManager = TemporaryZoneIndicatorManager()
    internal let addZoneIndicatorManager = AddZoneIndicatorManager()
    internal let resizeHandleManager = ZoneResizeHandleManager()
    internal lazy var displacedWindowCoordinator = DisplacedWindowCoordinator(host: self)
    internal lazy var temporaryZoneCoordinator = TemporaryZoneCoordinator(
        host: self,
        displacedWindowCoordinator: displacedWindowCoordinator
    )
    internal lazy var temporaryDragHandler = TemporaryDragHandler(host: self)
    internal var tiledToTemporaryDragContexts: [Int: TiledToTemporaryDragContext] = [:]
    internal let addIndicatorTracker = EdgeIndicatorTracker()
    internal let temporaryIndicatorTracker = EdgeIndicatorTracker()
    internal let menuBarManager = MenuBarManager()
    internal let winShotManager = WinShotManager()
    internal lazy var winShotChooserController: WinShotChooserController = {
        let controller = WinShotChooserController()
        controller.delegate = self
        return controller
    }()
    internal var pendingScreenChangeWorkItem: DispatchWorkItem?
    internal var pendingScreenChangeReason: String?
    internal var pendingScreenChangeDisplayIds: Set<CGDirectDisplayID> = []
    internal let screenChangeDebounceInterval: TimeInterval = 0.25
    internal let manualMoveSuppressionDuration: TimeInterval = 1.5
    internal var manualMoveSuppressionDeadline: Date?
    /// Windows that were manually resized while tiled and should snap back to their zone frame on focus loss or the next layout sync.
    internal var manualResizeDetachedWindowIds: Set<Int> = []
    internal let activeFitOverflowTolerance: CGFloat = 1.0
    internal var activeFitState: ActiveFitState?
    internal var activeFitSuppressedWindowIds: Set<Int> = []
    internal var activeFitZoneResizeLoggedWindowIds: Set<Int> = []
    internal var pendingTemporaryZoneIdentitySnapshots: [CGDirectDisplayID: TemporaryZoneIdentitySnapshot] = [:]
    internal var temporaryZoneWakeProtectionDeadlines: [Int: Date] = [:]
    internal let temporaryZoneWakeProtectionDuration: TimeInterval = 5.0
    internal var pendingZoneAssignmentSnapshots: [ZoneKey: ZoneAssignmentSnapshot] = [:]
    internal var liveZoneAssignments: [ZoneKey: ZoneAssignmentSnapshot] = [:]
    struct SuppressionEntry {
        var remaining: Int
        var deadline: Date
    }

    internal var eventSuppressions: [Int: [SuppressedEvent: SuppressionEntry]] = [:]

    // Computed property for backward compatibility
    internal var targetedZoneKey: ZoneKey? {
        targetedZoneManager.targetedZoneKey
    }

    internal var targetedTemporaryScreenId: CGDirectDisplayID? {
        targetedZoneManager.targetedTemporaryScreenId
    }

    internal var screenContexts: [CGDirectDisplayID: ScreenContext] {
        screenContextStore.contexts
    }

    internal var screenOrder: [CGDirectDisplayID] {
        screenContextStore.order
    }

    /// Screens sorted from left to right using visible screen bounds in screen coordinates.
    internal var screenOrderLeftToRight: [CGDirectDisplayID] {
        let contexts = screenContexts
        var ordered = screenOrder
        for screenId in contexts.keys where !ordered.contains(screenId) {
            ordered.append(screenId)
        }

        func sortKey(for screenId: CGDirectDisplayID) -> (CGFloat, CGFloat, CGDirectDisplayID) {
            guard let descriptor = contexts[screenId]?.descriptor else {
                return (.greatestFiniteMagnitude, .greatestFiniteMagnitude, screenId)
            }
            let bounds = descriptor.visibleScreenBounds
            return (bounds.minX, bounds.minY, screenId)
        }

        return ordered.sorted { lhs, rhs in
            let leftKey = sortKey(for: lhs)
            let rightKey = sortKey(for: rhs)
            if leftKey.0 == rightKey.0 {
                if leftKey.1 == rightKey.1 {
                    return leftKey.2 < rightKey.2
                }
                return leftKey.1 < rightKey.1
            }
            return leftKey.0 < rightKey.0
        }
    }

    internal var dragExcludedZones: Set<ZoneKey> {
        dragDropCoordinator.dragExcludedZones
    }

    private override init() {
        let configuration = Configuration.load()
        self.configuration = configuration

        let screens = NSScreen.screens
        guard let contextStore = ScreenContextStore(screens: screens) else {
            fatalError("No primary screen found")
        }

        self.screenContextStore = contextStore
        self.primaryScreenId = contextStore.primaryDisplayId
        self.primaryScreenBounds = contextStore.primaryScreenBounds

        self.windowController = WindowController(
            ignoredBundleIdentifiers: configuration.ignoredBundleIdentifiers,
            primaryScreenBounds: contextStore.primaryScreenBounds,
            applicationExceptionPolicy: configuration.applicationExceptionPolicy
        )
        self.capturePipeline = WindowCapturePipeline(windowController: self.windowController)
        self.placeholderCoordinator = PlaceholderCoordinator(windowController: self.windowController)

        super.init()

        self.capturePipeline.delegate = self
        self.placeholderCoordinator.delegate = self
        self.windowController.delegate = self
        self.indicatorManager.delegate = self
        self.temporaryIndicatorManager.delegate = self
        self.addZoneIndicatorManager.delegate = self
        self.resizeHandleManager.delegate = self
        self.validationRetryManager.delegate = self
        self.targetedZoneManager.delegate = self
        self.targetedZoneManager.initialize(primaryScreenId: primaryScreenId)
        self.windowPlacementManager.delegate = self
        self.dragDropCoordinator.delegate = self
        self.menuBarManager.delegate = self
        prepareExistingApplicationWindows()
        hotkeyService.start(delegate: self)
        systemEventMonitor.start(delegate: self)
        displayMonitor.start(delegate: self)
        zoneClickInterceptor.start(delegate: self)

        Logger.debug("AppController initialized with multi-screen support across \(screenContexts.count) display(s)")

        // Create initial placeholder for the first empty zone
        syncWindowsToZones()
        targetedZoneManager.ensureTargetedZone(reason: "startup")
        if !hasAvailableTiledZone() {
            targetedZoneManager.setTemporaryTarget(on: primaryScreenId, reason: "startup-all-zones-filled")
        }
        refreshIndicators()
    }

    deinit {
        capturePipeline.cancelAllRetries()
        hotkeyService.stop()
        systemEventMonitor.stop()
        displayMonitor.stop()
        zoneClickInterceptor.stop()
        pendingScreenChangeWorkItem?.cancel()
        indicatorManager.tearDown()
        temporaryIndicatorManager.tearDown()
        addZoneIndicatorManager.tearDown()
        menuBarManager.tearDown()
    }

    private static func displayId(for screen: NSScreen) -> CGDirectDisplayID? {
        ScreenContextStore.displayId(for: screen)
    }

    internal func activeScreenId() -> CGDirectDisplayID {
        let cursorScreenId = resolveCursorScreenId()

        let mainScreenId: CGDirectDisplayID? = {
            guard let main = NSScreen.main,
                  let id = AppController.displayId(for: main),
                  screenContexts[id] != nil else {
                return nil
            }
            return id
        }()

        if let cursor = cursorScreenId,
           let main = mainScreenId,
           cursor == main {
            return cursor
        }

        let targetedScreenId: CGDirectDisplayID? = {
            if let tiled = targetedZoneManager.targetedZoneKey?.screenId,
               screenContexts[tiled] != nil {
                return tiled
            }
            if let temporary = targetedZoneManager.targetedTemporaryScreenId,
               screenContexts[temporary] != nil {
                return temporary
            }
            return nil
        }()

        if let target = targetedScreenId {
            if let cursor = cursorScreenId, cursor == target {
                return cursor
            }
            if let main = mainScreenId, main == target {
                return main
            }
        }

        if let main = mainScreenId {
            return main
        }
        if let cursor = cursorScreenId {
            return cursor
        }
        if screenContexts[primaryScreenId] != nil {
            return primaryScreenId
        }
        return screenOrder.first ?? primaryScreenId
    }

    internal func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor? {
        screenContexts[screenId]?.descriptor
    }
}
