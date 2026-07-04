/// Primary coordination hub for zone management, window placement, and system integration
import Foundation
import AppKit
import ApplicationServices

class AppController: NSObject, WindowControllerDelegate, ZoneIndicatorManagerDelegate, ZoneResizeHandleManagerDelegate, FloatingZoneIndicatorManagerDelegate, AddZoneIndicatorManagerDelegate, ValidationRetryManagerDelegate, TargetedZoneManagerDelegate, WindowPlacementManagerDelegate, DragDropCoordinatorDelegate, HotkeyServiceDelegate, SystemEventMonitorDelegate, WindowCapturePipelineDelegate, PlaceholderCoordinatorDelegate, PlaceholderManagerDelegate, DisplayReconfigurationMonitorDelegate, ZoneClickInterceptorDelegate, MenuBarManagerDelegate, FloatingZoneCoordinatorHost, FloatingDragHandlerHost, DisplacedWindowCoordinatorHost, DeferredMinimizationCoordinatorHost, FullScreenTrackerDelegate, ExternalZoneDropInterceptorHost {
    enum SuppressedEvent: String {
        case miniaturized
        case deminiaturized
    }
    struct FloatingFloatingDragState {
        let windowId: Int
        var hoveredAddZonePill: AddZonePillKey?
        var hoveredFloatingScreenId: CGDirectDisplayID?
    }
    struct ZoneEdgeMargins {
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat
    }
    struct TiledToFloatingDragContext {
        let originZoneKey: ZoneKey?
        let originScreenId: CGDirectDisplayID?
        let floatingScreenId: CGDirectDisplayID
        let displacedWindowId: Int?
        let displacedWindowFrame: CGRect?
    }
    struct UnmanagedFocusRetryState {
        let pid: pid_t
        var attempt: Int
        var workItem: DispatchWorkItem?
    }
    struct ManualResizeCleanupState {
        let wasDetached: Bool
        let rememberedSize: CGSize?
    }
    struct UnmanagedWindowEdgeDragState {
        let elementKey: AccessibilityElementKey
        let pid: pid_t
        var cgWindowId: Int?
        let originFrame: CGRect
        var latestFrame: CGRect
        var isActive: Bool
        var parkedCapturedWindowId: Int?
        var hoveredAddZonePill: AddZonePillKey?
        var hoveredFloatingScreenId: CGDirectDisplayID?
    }
    static let shared = AppController()

    internal let windowController: WindowController
    internal var configuration: Configuration
    internal let validationRetryManager = ValidationRetryManager()
    internal let targetedZoneManager = TargetedZoneManager()
    internal let windowPlacementManager = WindowPlacementManager()
    internal let browserLaunchController = BrowserLaunchController()
    internal let dragDropCoordinator = DragDropCoordinator()
    internal let screenContextStore: ScreenContextStore
    internal let hotkeyService = HotkeyService()
    internal let cmdTabKeyInterceptor = CmdTabKeyInterceptor()
    internal let windowFocusNavigationInterceptor = WindowFocusNavigationInterceptor()
    internal let windowFocusDotOverlay = WindowFocusDotOverlay()
    /// Live state for an in-progress Control-Command window-focus gesture, or nil when idle.
    internal var windowFocusNavigationState: WindowFocusNavigationState?
    internal let systemEventMonitor = SystemEventMonitor()
    internal let displayMonitor = DisplayReconfigurationMonitor()
    internal let zoneClickInterceptor = ZoneClickInterceptor()
    internal lazy var externalZoneDropInterceptor = ExternalZoneDropInterceptor(host: self)
    // Cached primary-display identity/bounds. Refreshed on every screen-topology change from the
    // screen-context store (the single source of truth) via refreshCachedPrimaryScreenBounds().
    internal var primaryScreenId: CGDirectDisplayID  // stable CGDirectDisplayID
    internal var primaryScreenBounds: CGRect
    internal let zoneMargin: CGFloat = 8
    internal let edgeAlignmentTolerance: CGFloat = 0.5
    internal var isSyncingWindows = false
    internal var pendingSync = false
    internal var pendingSyncRecentlyPlacedInFloatingZone: Int?
    /// PIDs already queued for next-runloop native-tab validation after a global sync deferral.
    internal var pendingNativeTabPidValidationRequests: Set<pid_t> = []
    /// Window IDs whose geometry reapply should be skipped for an immediate full sync pass.
    internal var pendingSyncSkipGeometryWindowIds: Set<Int> = []
    /// Next-runloop cleanup for unconsumed sync geometry-skip marks.
    internal var pendingSyncSkipGeometryCleanupWorkItem: DispatchWorkItem?
    internal var lastSyncKnownZoneKeys: Set<ZoneKey> = []
    internal var lastSyncEmptyZoneKeys: Set<ZoneKey> = []
    internal var liveResizingZoneKey: ZoneKey?
    /// The screen being resized during a zone resize drag, or nil if no drag is active.
    /// Used to temporarily suppress ActiveFit and AX frame retries during the gesture.
    internal var zoneResizeDragScreenId: CGDirectDisplayID?
    internal var zoneResizeDragInProgress: Bool { zoneResizeDragScreenId != nil }
    /// Per-window target frames from the previous live-resize tick.
    /// Used to detect which frame components changed so we can skip unchanged AX writes.
    /// Cleared when the drag ends.
    internal var liveResizePreviousFrames: [Int: CGRect] = [:]
    internal var lastActiveApplicationPid: pid_t?
    /// False while `init` seeds windows and sets the initial target; true once startup completes.
    /// Gates the target-change border flash so launching the app doesn't flash while zones are seeded.
    internal var hasCompletedInitialStartup = false
    /// When true, target changes do not flash the zone border. Scoped via `withTargetChangeFlashSuppressed`
    /// around operations (e.g. creating a zone) whose retarget should not draw a flash.
    internal var suppressTargetChangeFlash = false
    internal let capturePipeline: WindowCapturePipeline
    internal let placeholderManager: PlaceholderManager
    internal let placeholderCoordinator: PlaceholderCoordinator
    internal let occupiedZoneTargetOverlay = OccupiedZoneTargetOverlay()
    internal let indicatorManager = ZoneIndicatorManager()
    internal let floatingIndicatorManager = FloatingZoneIndicatorManager()
    internal let addZoneIndicatorManager = AddZoneIndicatorManager()
    internal let resizeHandleManager = ZoneResizeHandleManager()
    /// Screens whose resize bars are temporarily pinned visible after placeholder activation.
    internal var pinnedResizeBarScreenIds: Set<CGDirectDisplayID> = []
    internal var pinnedResizeBarClickMonitor: ClickOutsideMonitor?
    internal let placeholderExternalDragOverlayManager = DragOverlayManager()
    internal var placeholderExternalDragOverlayKey: ZoneKey?
    internal var placeholderExternalDragOverlayTeardownWorkItem: DispatchWorkItem?
    /// True once AppKit has confirmed a real external drag entered a placeholder during the current mouse gesture.
    /// This avoids treating stale `.drag` pasteboard contents as a live drag.
    internal var hasObservedRealPlaceholderExternalDragThisGesture = false
    /// Captured bundle identifier for the app that started the current external drag gesture.
    internal var externalDragSourceBundleIdentifier: String?
    internal lazy var displacedWindowCoordinator = DisplacedWindowCoordinator(host: self)
    internal lazy var deferredMinimizationCoordinator = DeferredMinimizationCoordinator(host: self)
    internal let minimizeLoopGuard = MinimizeLoopGuard()
    internal lazy var floatingZoneCoordinator = FloatingZoneCoordinator(
        host: self,
        displacedWindowCoordinator: displacedWindowCoordinator
    )
    internal lazy var floatingDragHandler = FloatingDragHandler(host: self)
    internal let floatingDragOverlayManager = DragOverlayManager()
    /// Tracks screens where the single-zone placeholder has been temporarily hidden (UnderCovers mode).
    internal var underCoversScreens: Set<CGDirectDisplayID> = []
    /// Screen ID where an unmanaged window currently has focus, or nil if the active window is managed.
    /// Used to hide zone resize bars on that screen.
    internal var unmanagedFocusedWindowScreenId: CGDirectDisplayID?
    /// Retry state for unresolved unmanaged-focus classification.
    /// A focus is only treated as unmanaged once confirmed; transient AX failures retry first.
    internal var unmanagedFocusRetryState: UnmanagedFocusRetryState?
    internal let unmanagedFocusRetryDelays: [TimeInterval] = [0.2, 0.4, 0.8, 1.6, 3.2]
    /// The window ID of the currently frontmost managed window, or nil if no managed window is focused.
    /// Updated by windowFocusChanged; used by CmdTab to determine initial selection without an AX call.
    /// All mutations must go through `setCurrentFrontmostManagedWindowId(_:reason:)` so transitions
    /// are logged — resize-bar visibility depends on this value.
    internal private(set) var currentFrontmostManagedWindowId: Int?

    /// Updates `currentFrontmostManagedWindowId` and logs each transition with a short reason, so
    /// we can explain why the resize-handle avoidance frame changed (or was missing) when
    /// diagnosing bar-overlap bugs.
    internal func setCurrentFrontmostManagedWindowId(_ newValue: Int?, reason: String) {
        let oldValue = currentFrontmostManagedWindowId
        guard oldValue != newValue else { return }
        currentFrontmostManagedWindowId = newValue
        let oldDescription = oldValue.map { "window \($0)" } ?? "none"
        let newDescription = newValue.map { "window \($0)" } ?? "none"
        Logger.debug("Frontmost managed window: \(oldDescription) -> \(newDescription) (reason: \(reason))")
    }
    /// Last logged fingerprint per screen for `refreshResizeHandles`. Refreshes that produce the
    /// same inputs and per-separator outcomes are suppressed to keep the log readable during
    /// sync/focus bursts.
    internal var lastLoggedResizeHandleFingerprint: [CGDirectDisplayID: String] = [:]
    internal var tiledToFloatingDragContexts: [Int: TiledToFloatingDragContext] = [:]
    internal var unmanagedWindowEdgeDragState: UnmanagedWindowEdgeDragState?
    internal var unmanagedWindowEdgeDragLocalMouseUpMonitor: Any?
    internal var unmanagedWindowEdgeDragGlobalMouseUpMonitor: Any?
    internal var unmanagedWindowEdgeDragSuppressedManagedWindowIds: Set<Int> = []
    internal var unmanagedWindowEdgeIndicatorMousePassthroughEnabled = false
    internal let addIndicatorTracker = EdgeIndicatorTracker<AddZonePillKey>()
    internal let floatingIndicatorTracker = EdgeIndicatorTracker<CGDirectDisplayID>()
    internal let menuBarManager = MenuBarManager()
    internal let updateChecker = UpdateChecker()
    internal var isPresentingUpdateCheckAlert = false
    internal let launcherInstallWatchService = LauncherInstallWatchService()
    internal let winShotManager = WinShotManager()
    internal let winShotOccupancyAutoSaveScheduler = WinShotOccupancyAutoSaveScheduler()
    internal lazy var winShotChooserController: WinShotChooserController = {
        let controller = WinShotChooserController()
        controller.delegate = self
        return controller
    }()
    internal lazy var launcherController: LauncherController = {
        let controller = LauncherController()
        controller.delegate = self
        return controller
    }()
    internal lazy var cmdTabController: CmdTabController = {
        let controller = CmdTabController()
        controller.delegate = self
        return controller
    }()
    internal var fullScreenTracker: FullScreenTracker!
    internal var fullScreenDebugOverlay: FullScreenDebugOverlayController?
    internal var fullScreenElementCache: [AccessibilityElementKey: FullScreenElementInfo] = [:]
    internal var fullScreenCheckWorkItemsByWindowId: [Int: DispatchWorkItem] = [:]
    internal var fullScreenCheckWorkItemsByElement: [AccessibilityElementKey: DispatchWorkItem] = [:]
    internal var pendingFullScreenSpaceChangeWorkItem: DispatchWorkItem?
    /// True when Launcher should auto-show for empty tiling zones.
    internal var autoShowLauncherForEmptyTilingZonesEnabled: Bool
    /// True when manually resized tiled windows should restore their remembered size on re-activation.
    internal var stickyResizeEnabled: Bool
    /// True when DockMenus should use the active window's zone for placement-oriented actions.
    internal var dockMenusTargetsZoneWithActiveWindowEnabled: Bool
    /// Which CmdTab shortcuts temporarily retarget to the active window's zone before opening.
    internal var cmdTabActiveWindowTargetingMode: CmdTabActiveWindowTargetingMode
    /// True when the Launcher keyboard shortcut should retarget to the active window's zone before opening.
    internal var launcherShortcutTargetsZoneWithActiveWindowEnabled: Bool
    internal var dockMenusCoordinator: DockMenusCoordinator?
    internal var pendingScreenChangeWorkItem: DispatchWorkItem?
    internal var pendingScreenChangeReason: String?
    /// True when the pending screen-topology refresh includes a wake trigger.
    internal var pendingScreenChangeIncludesWake: Bool = false
    internal var pendingScreenChangeDisplayIds: Set<CGDirectDisplayID> = []
    /// Pending recapture work items that should be cancelled when screens go to sleep.
    internal var pendingRecaptureWorkItems: [DispatchWorkItem] = []
    internal let screenChangeDebounceInterval: TimeInterval = 0.25
    internal let fullScreenCheckDebounceInterval: TimeInterval = 0.25
    internal let fullScreenSpaceChangeDebounceInterval: TimeInterval = 0.25
    internal let manualMoveSuppressionDuration: TimeInterval = 1.5
    internal var manualMoveSuppressionDeadline: Date?
    /// Windows that were manually resized while tiled and should snap back to their zone frame on focus loss or the next layout sync.
    internal var manualResizeDetachedWindowIds: Set<Int> = []
    /// Remembered manual tiled-window sizes used by Sticky Resize when the window becomes active again.
    internal var rememberedManualResizeSizesByWindowId: [Int: CGSize] = [:]
    /// Debounce state for per-app self-resize snap-to-zone exceptions.
    internal var selfResizeSnapDebouncer = WindowFrameDebouncer(minimumInterval: 0.25)
    /// Edge proximity threshold (in pixels, screen-local) for classifying a resize as a user edge-drag.
    internal let userResizeEdgeProximityThreshold: CGFloat = 6
    /// Time window after mouse-up where we still classify a border-adjacent resize as user-driven.
    internal let userResizeMouseUpGraceInterval: TimeInterval = 0.35

    // MARK: - Sleep/Wake State
    /// Timer used to poll for wake readiness (display awake + session unlocked).
    internal var wakeReadinessTimer: DispatchSourceTimer?
    /// Timestamp captured when wake readiness polling starts.
    internal var wakeReadinessPollingStartedAt: Date?
    /// Number of wake readiness polling attempts in the current cycle.
    internal var wakeReadinessPollingAttemptCount: Int = 0
    /// Timer used to poll for AX window readiness during sleep/wake restoration.
    internal var wakeAXWindowPollingTimer: DispatchSourceTimer?
    /// True between screensDidSleepNotification and completion of the wake pipeline.
    /// When true, we ignore all external events to avoid reacting to AX errors
    /// during the sleep/wake transition.
    internal var screensAsleep: Bool = false
    /// Ensures we only re-key the Launcher once while waiting for wake readiness.
    internal var wakeLauncherFocusRequested: Bool = false

    // MARK: - ActiveFit State (reveal mode vs rest mode)
    /// Tolerance in pixels for determining if a window overflows in rest mode and needs reveal mode.
    internal let activeFitOverflowTolerance: CGFloat = 1.0
    /// Tracks which window is currently in reveal mode (shifted to fit on screen). Only one window at a time.
    internal var activeFitState: ActiveFitState?
    /// Windows temporarily excluded from reveal mode evaluation (e.g., during drag or restore flows).
    internal var activeFitSuppressedWindowIds: Set<Int> = []
    /// Windows for which we've already logged zone-resize suppression (prevents log spam).
    internal var activeFitZoneResizeLoggedWindowIds: Set<Int> = []
    internal var floatingZoneProtectionDeadlines: [Int: Date] = [:]
    internal let floatingZoneProtectionDuration: TimeInterval = 0.5
    /// Work items scheduled to reactivate floating zone windows when protection expires.
    internal var floatingZoneProtectionExpirationWorkItems: [Int: DispatchWorkItem] = [:]
    /// Deadline until which notification-driven window activity recording is suppressed
    /// to prevent "twitchy" recordings during floating zone/WinShot operations.
    internal var activityRecordingSuppressedUntil: Date?
    /// Minimum time a window must remain focused before it is recorded for CmdTab/Launcher recency ordering.
    internal let windowActivityRecordingStabilityDelay: TimeInterval = 0.25
    /// Pending delayed activity recording work item for the currently focused window.
    internal var pendingWindowActivityRecordWorkItem: DispatchWorkItem?
    /// Monotonic token used to invalidate previously scheduled recordings.
    internal var pendingWindowActivityRecordToken: Int = 0
    /// Active Launcher shortcut-targeting session, used to toggle between the session's
    /// original target and the currently active window's destination while Launcher is open.
    internal var launcherRetargetSession: TemporaryRetargetSession?
    /// Set (via `performTargetChangeKeepingLauncherVisible`) by target-changing keyboard shortcuts —
    /// directional navigation (Control-Cmd-arrows) and "Toggle Target Zone w/ Focused Window" — so the
    /// retarget keeps an already-visible Launcher anchored to the new target, even when that target is
    /// an occupied tiling zone, rather than dismissing it. Restored after the retarget is processed.
    internal var keepLauncherVisibleAcrossTargetNavigation: Bool = false
    /// True only while a tentative in-chooser retarget (the "Toggle Target Zone w/ Focused Window"
    /// shortcut) is being applied. Suppresses the chooser-session invalidation in the refresh paths so
    /// the session survives to be rebound and restored on cancel, instead of being committed like an
    /// ordinary navigation/external retarget.
    internal var isApplyingTentativeChooserRetarget = false
    /// Active CmdTab temporary-retarget session, if CmdTab opened after changing the target.
    internal var cmdTabRetargetSession: TemporaryRetargetSession?
    /// The app that was frontmost when the current CmdTab session opened. It is that session's
    /// single "current app": it both filters app-specific mode and receives the in-CmdTab
    /// "new window" (Cmd-N) keystroke, so the two can never disagree. Nil while CmdTab is closed.
    internal var cmdTabCurrentAppPid: pid_t?
    /// Delay before evaluating reveal mode after a restore flow (WinShot, sleep/wake).
    internal let activeFitRestoreDelay: TimeInterval = 1.0
    struct SuppressionEntry {
        var remaining: Int
        var deadline: Date
    }

    internal var eventSuppressions: [Int: [SuppressedEvent: SuppressionEntry]] = [:]

    /// Tracks the active window that needs re-raising after each unminimize animation completes
    /// during WinShot restoration. Cleared when all expected deminiaturize notifications arrive.
    struct PendingRestoreRaise {
        let element: AXUIElement
        let pid: pid_t
        var pendingWindowIds: Set<Int>
    }
    internal var pendingRestoreRaise: PendingRestoreRaise?
    /// Minimized windows explicitly selected or dropped by the user should become frontmost
    /// after the deminiaturize path finishes placement or native-tab adoption.
    internal var pendingExplicitUnminimizeFocusWindowIds: Set<Int> = []

    // Computed property for backward compatibility
    internal var targetedZoneKey: ZoneKey? {
        targetedZoneManager.targetedZoneKey
    }

    internal var targetedFloatingScreenId: CGDirectDisplayID? {
        targetedZoneManager.targetedFloatingScreenId
    }

    internal var screenContexts: [CGDirectDisplayID: ScreenContext] {
        screenContextStore.contexts
    }

    internal var screenOrder: [CGDirectDisplayID] {
        screenContextStore.order
    }

    internal var fullScreenDisplayIds: Set<CGDirectDisplayID> {
        fullScreenTracker?.fullScreenDisplayIds ?? []
    }

    private override init() {
        // Ensure config.json exists (seeded from bundled defaults if needed)
        ExceptionsConfigurationStore.ensureConfigExists()

        let configuration = Configuration.load()
        self.configuration = configuration
        self.autoShowLauncherForEmptyTilingZonesEnabled = LauncherBehaviorPreferencesStore.loadAutoShowForEmptyZones()
        self.stickyResizeEnabled = StickyResizePreferencesStore.loadEnabled()
        self.dockMenusTargetsZoneWithActiveWindowEnabled = DockMenusBehaviorPreferencesStore.loadTargetsZoneWithActiveWindow()
        self.cmdTabActiveWindowTargetingMode = CmdTabBehaviorPreferencesStore.loadTargetingMode()
        self.launcherShortcutTargetsZoneWithActiveWindowEnabled = LauncherBehaviorPreferencesStore.loadShortcutTargetsZoneWithActiveWindow()

        let screens = NSScreen.screens
        guard let contextStore = ScreenContextStore(
            screens: screens,
            zoneLayoutStyle: ZoneLayoutStylePreferencesStore.loadStyle()
        ) else {
            fatalError("No primary screen found")
        }

        self.screenContextStore = contextStore
        self.primaryScreenId = contextStore.primaryDisplayId
        self.primaryScreenBounds = contextStore.primaryScreenBounds

        self.windowController = WindowController(
            ignoredBundleIdentifiers: configuration.ignoredBundleIdentifiers,
            nativeTabHandlingDisabled: DebugPreferencesStore.loadDisableNativeTabHandling(),
            primaryScreenBounds: contextStore.primaryScreenBounds,
            applicationExceptionPolicy: configuration.applicationExceptionPolicy
        )
        self.capturePipeline = WindowCapturePipeline(windowController: self.windowController)
        self.placeholderManager = PlaceholderManager()
        self.placeholderCoordinator = PlaceholderCoordinator(placeholderManager: self.placeholderManager)

        // Initialize full-screen debug overlay from persisted Debug preferences
        self.fullScreenDebugOverlay = DebugPreferencesStore.loadFullScreenOverlayEnabled()
            ? FullScreenDebugOverlayController(primaryScreenBounds: contextStore.primaryScreenBounds)
            : nil

        super.init()

        // Initialize full-screen tracker after super.init()
        self.fullScreenTracker = FullScreenTracker()
        self.fullScreenTracker.delegate = self

        // Listen for exception config changes from Preferences
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExceptionsConfigurationDidChange),
            name: .exceptionsConfigurationDidChange,
            object: nil
        )

        // Recompute resize-bar suppression when our Preferences window gains/loses key status.
        // Activation notifications only fire on app switches; these catch intra-Zonogy focus
        // moves (e.g. the Launcher opening over Preferences) so suppression never lingers.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreferencesWindowKeyStateChange(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreferencesWindowKeyStateChange(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        self.capturePipeline.delegate = self
        self.placeholderCoordinator.delegate = self
        self.placeholderManager.delegate = self
        self.windowController.delegate = self
        self.indicatorManager.delegate = self
        self.floatingIndicatorManager.delegate = self
        self.addZoneIndicatorManager.delegate = self
        self.resizeHandleManager.delegate = self
        self.validationRetryManager.delegate = self
        self.targetedZoneManager.delegate = self
        self.targetedZoneManager.initialize(primaryScreenId: primaryScreenId)
        self.windowPlacementManager.delegate = self
        self.dragDropCoordinator.delegate = self
        self.menuBarManager.delegate = self
        // Refresh an open chooser once a snapshot's async composited thumbnail lands.
        self.winShotManager.onThumbnailReady = { [weak self] screenId, _ in
            self?.refreshWinShotChooserIfNeeded(for: screenId)
        }
        self.launcherInstallWatchService.reloadHandler = { [weak self] in
            self?.reloadLauncherItems()
        }
        prepareExistingApplicationWindows()
        scanAllWindowsForFullScreenState()
        hotkeyService.start(delegate: self)
        systemEventMonitor.start(delegate: self)
        displayMonitor.start(delegate: self)
        zoneClickInterceptor.start(delegate: self)
        externalZoneDropInterceptor.start()
        cmdTabKeyInterceptor.start(delegate: self)
        windowFocusNavigationInterceptor.start(delegate: self)
        startDockMenusIfConfigured()
        startUpdateChecker()

        Logger.debug("AppController initialized with multi-screen support across \(screenContexts.count) display(s)")

        // Create initial placeholder for the first empty zone
        syncWindowsToZones()
        targetedZoneManager.ensureTargetedZone(reason: "startup")
        if !hasAvailableTiledZone() {
            targetedZoneManager.setFloatingTarget(on: primaryScreenId, reason: "startup-all-zones-filled")
        }
        refreshIndicators()

        // Startup seeding and initial targeting are complete; allow target-change border flashes now.
        hasCompletedInitialStartup = true

        // Watch app install roots and refresh launcher cache when installations change.
        launcherInstallWatchService.start()

        // Pre-load launcher app list in background for instant launcher opens
        Task.detached(priority: .utility) {
            await LauncherAppCache.shared.preload()
        }
    }

    /// Reloads all configuration from config.json: ignoredBundleIdentifiers, applicationExceptionPolicy,
    /// deriveBundleIdFromPathForProcesses, and refreshes the launcher app cache.
    internal func reloadConfiguration() {
        let newConfig = Configuration.load()
        self.configuration = newConfig
        self.windowController.ignoredBundleIdentifiers = newConfig.ignoredBundleIdentifiers
        self.windowController.applicationExceptionPolicy = newConfig.applicationExceptionPolicy
        Logger.debug("Reloaded configuration: \(newConfig.ignoredBundleIdentifiers.count) ignored bundles, \(newConfig.deriveBundleIdFromPathForProcesses.count) bundle-derived processes")
        reloadLauncherItems()
    }

    @objc private func handlePreferencesWindowKeyStateChange(_ notification: Notification) {
        guard (notification.object as? NSWindow)?.identifier == PreferencesWindowController.windowIdentifier else {
            return
        }
        // Defer to the next runloop tick so the key-window transition has settled before we
        // recompute. Mid-transition (e.g. a Launcher/CmdTab panel taking key over Preferences)
        // `NSApp.keyWindow` can momentarily be nil; recomputing then would read the stale
        // mainWindow fallback and keep suppression, and the panel's own key notification is
        // filtered out here. Reading after the tick sees the true new key window.
        DispatchQueue.main.async { [weak self] in
            self?.updateUnmanagedFocusState()
        }
    }

    @objc private func handleExceptionsConfigurationDidChange() {
        // Ensure we're on main thread since we mutate shared state
        DispatchQueue.main.async { [weak self] in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let self = self else { return }
            self.reloadConfiguration()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        capturePipeline.cancelAllRetries()
        hotkeyService.stop()
        windowFocusNavigationInterceptor.stop()
        windowFocusDotOverlay.hide()
        systemEventMonitor.stop()
        displayMonitor.stop()
        zoneClickInterceptor.stop()
        externalZoneDropInterceptor.stop()
        stopDockMenus()
        launcherInstallWatchService.stop()
        pendingScreenChangeWorkItem?.cancel()
        indicatorManager.tearDown()
        floatingIndicatorManager.tearDown()
        addZoneIndicatorManager.tearDown()
        occupiedZoneTargetOverlay.hide()
        placeholderExternalDragOverlayManager.tearDown()
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
            if let floating = targetedZoneManager.targetedFloatingScreenId,
               screenContexts[floating] != nil {
                return floating
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
