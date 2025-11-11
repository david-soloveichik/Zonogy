/// Primary coordination hub for zone management, window placement, and system integration
import Foundation
import AppKit
import ApplicationServices

class AppController: NSObject, WindowControllerDelegate, ZoneIndicatorManagerDelegate, AddZoneIndicatorManagerDelegate, ValidationRetryManagerDelegate, TargetedZoneManagerDelegate, WindowPlacementManagerDelegate, DragDropCoordinatorDelegate, HotkeyServiceDelegate, SystemEventMonitorDelegate, WindowCapturePipelineDelegate, PlaceholderCoordinatorDelegate, DisplayReconfigurationMonitorDelegate, ZoneClickInterceptorDelegate, MenuBarManagerDelegate {
    struct ZoneEdgeMargins {
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat
    }

    static let shared = AppController()

    internal let windowController: WindowController
    internal let configuration: Configuration
    internal let validationRetryManager = ValidationRetryManager()
    internal let targetedZoneManager = TargetedZoneManager()
    internal let windowPlacementManager = WindowPlacementManager()
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
    internal var lastActiveApplicationPid: pid_t?
    internal let capturePipeline: WindowCapturePipeline
    internal let placeholderCoordinator: PlaceholderCoordinator
    internal let indicatorManager = ZoneIndicatorManager()
    internal let addZoneIndicatorManager = AddZoneIndicatorManager()
    internal let menuBarManager = MenuBarManager()
    internal var pendingScreenChangeWorkItem: DispatchWorkItem?
    internal var pendingScreenChangeReason: String?
    internal var pendingScreenChangeDisplayIds: Set<CGDirectDisplayID> = []
    internal let screenChangeDebounceInterval: TimeInterval = 0.25
    internal let manualMoveSuppressionDuration: TimeInterval = 1.5
    internal var manualMoveSuppressionDeadline: Date?
    internal var currentAddZoneIndicatorHitAreas: [CGDirectDisplayID: CGRect] = [:]
    internal let keyFitOverflowTolerance: CGFloat = 1.0
    internal var keyFitState: KeyFitState?
    internal var keyFitSuppressedWindowIds: Set<Int> = []

    // Computed property for backward compatibility
    internal var targetedZoneKey: ZoneKey? {
        targetedZoneManager.targetedZoneKey
    }

    internal var screenContexts: [CGDirectDisplayID: ScreenContext] {
        screenContextStore.contexts
    }

    internal var screenOrder: [CGDirectDisplayID] {
        screenContextStore.order
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
            primaryScreenBounds: contextStore.primaryScreenBounds
        )
        self.capturePipeline = WindowCapturePipeline(windowController: self.windowController)
        self.placeholderCoordinator = PlaceholderCoordinator(windowController: self.windowController)

        super.init()

        self.capturePipeline.delegate = self
        self.placeholderCoordinator.delegate = self
        self.windowController.delegate = self
        self.indicatorManager.delegate = self
        self.addZoneIndicatorManager.delegate = self
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
        addZoneIndicatorManager.tearDown()
        menuBarManager.tearDown()
    }

    private static func displayId(for screen: NSScreen) -> CGDirectDisplayID? {
        ScreenContextStore.displayId(for: screen)
    }

    internal func activeScreenId() -> CGDirectDisplayID {
        if let main = NSScreen.main,
           let id = AppController.displayId(for: main),
           screenContexts[id] != nil {
            return id
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
