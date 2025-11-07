/// Primary coordination hub for zone management, window placement, and system integration
import Foundation
import AppKit
import ApplicationServices

class AppController: NSObject, WindowControllerDelegate, ZoneIndicatorManagerDelegate, AddZoneIndicatorManagerDelegate, ValidationRetryManagerDelegate, TargetedZoneManagerDelegate, WindowPlacementManagerDelegate, DragDropCoordinatorDelegate, HotkeyServiceDelegate, SystemEventMonitorDelegate, WindowCapturePipelineDelegate, PlaceholderCoordinatorDelegate, DisplayReconfigurationMonitorDelegate {
    private struct ZoneEdgeMargins {
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
    private let hotkeyService = HotkeyService()
    private let systemEventMonitor = SystemEventMonitor()
    private let displayMonitor = DisplayReconfigurationMonitor()
    let primaryScreenId: CGDirectDisplayID  // Internal tracking uses stable CGDirectDisplayID
    private let primaryScreenBounds: CGRect
    private let zoneMargin: CGFloat = 8
    private let edgeAlignmentTolerance: CGFloat = 0.5
    private var isSyncingWindows = false
    private var pendingSync = false
    private var pendingSyncExcludedZones: Set<ZoneKey> = []
    private var liveResizingZoneKey: ZoneKey?
    private var lastActiveApplicationPid: pid_t?
    private let capturePipeline: WindowCapturePipeline
    private let placeholderCoordinator: PlaceholderCoordinator
    private let indicatorManager = ZoneIndicatorManager()
    private let addZoneIndicatorManager = AddZoneIndicatorManager()
    private var pendingScreenChangeWorkItem: DispatchWorkItem?
    private var pendingScreenChangeReason: String?
    private var pendingScreenChangeDisplayIds: Set<CGDirectDisplayID> = []
    private let screenChangeDebounceInterval: TimeInterval = 0.25
    private let manualMoveSuppressionDuration: TimeInterval = 1.5
    private var manualMoveSuppressionDeadline: Date?

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

    private var dragExcludedZones: Set<ZoneKey> {
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
        prepareExistingApplicationWindows()
        hotkeyService.start(delegate: self)
        systemEventMonitor.start(delegate: self)
        displayMonitor.start(delegate: self)

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
        pendingScreenChangeWorkItem?.cancel()
        indicatorManager.tearDown()
        addZoneIndicatorManager.tearDown()
    }

    // MARK: - Zone Management

    func addZone() {
        let screenId = activeScreenId()
        addZone(on: screenId)
    }

    private func addZone(on screenId: CGDirectDisplayID) {
        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            print("Failed to add zone (max 3 zones)")
            return
        }
        syncWindowsToZones()
        let newZoneKey = zoneKey(for: screenId, index: newZone.index)
        if shouldRetarget(to: newZoneKey) {
            targetedZoneManager.setTargetedZone(newZoneKey, reason: "zone-added")
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "zone-added")
        }
        print("Added zone \(newZone.index) on \(context.descriptor.localizedName)")
    }

    func removeZone(at index: Int) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard performRemoveZone(at: index, on: screenId, announce: true, context: context) != nil else {
            print("Failed to remove zone \(index)")
            return
        }
    }

    internal func performRemoveZone(
        at index: Int,
        on screenId: CGDirectDisplayID,
        announce: Bool,
        context: ScreenContext? = nil
    ) -> ZoneController.RemovalResult? {
        let context = context ?? screenContexts[screenId]
        guard let context else {
            return nil
        }

        guard let removalResult = context.zoneController.removeZone(at: index) else {
            return nil
        }

        // Clear placeholder mappings for this screen since zones are being reindexed
        // This prevents stale mappings from causing duplicate placeholders
        placeholderCoordinator.clearMappingsForScreen(screenId)

        let currentTarget = targetedZoneKey
        var pendingTargetedKey: ZoneKey?
        if let currentTarget, currentTarget.screenId == screenId {
            if currentTarget.index == index {
                pendingTargetedKey = targetedZoneManager.fallbackTargetedZone(preferredScreenId: screenId)
            } else if currentTarget.index > index {
                pendingTargetedKey = ZoneKey(screenId: screenId, index: currentTarget.index - 1)
            }
        }

        if let pendingTargetedKey {
            targetedZoneManager.setTargetedZone(pendingTargetedKey, reason: "zone-removed")
        }

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            windowPlacementManager.handleWindowAfterZoneRemoval(managed, preferredScreenId: screenId)
        }

        syncWindowsToZones()

        if pendingTargetedKey == nil {
            targetedZoneManager.ensureTargetedZone(reason: "zone-removed")
        }

        if announce {
            print("Removed zone \(index) on \(context.descriptor.localizedName)")
        }
        return removalResult
    }

    func resizeZone(at index: Int, frame: CGRect) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard let zone = context.zoneController.zone(at: index) else {
            print("Zone \(index) not found on \(context.descriptor.localizedName)")
            return
        }

        guard zone.isEmpty else {
            print("Zone \(index) is occupied; minimize or close its window before resizing.")
            return
        }

        if context.zoneController.resizeZone(at: index, to: frame) {
            syncWindowsToZones()
            if let updatedZone = context.zoneController.zone(at: index) {
                print("Resized zone \(index) on \(context.descriptor.localizedName) to \(updatedZone.frame)")
            } else {
                print("Zone \(index) resized")
            }
        } else {
            print("Failed to resize zone \(index)")
        }
    }

    // MARK: - Window Management

    func createWindow() {
        let managed = windowController.createTestWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        windowPlacementManager.placeNewWindow(managed)
        print("Created window \(managed.windowId)")
    }

    func closeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        // Remove from zone
        removeWindowFromAllZones(windowId: windowId, reason: "close-command")

        // Close the window
        windowController.closeWindow(managed)

        // Sync to create placeholder if needed
        syncWindowsToZones()

        print("Closed window \(windowId)")
    }

    func minimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        windowController.minimizeWindow(managed)

        // Remove from zone and sync (delegate may not fire in CLI environment)
        removeWindowFromAllZones(windowId: windowId, reason: "minimize-command")
        syncWindowsToZones()

        print("Minimized window \(windowId)")
    }

    func unminimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        windowController.unminimizeWindow(managed)

        // Place the window using normal placement logic
        windowPlacementManager.placeNewWindow(managed)

        print("Unminimized window \(windowId)")
    }

    func captureFrontmostWindow() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            print("Frontmost application \(bundleId) is configured to be ignored.")
            return
        }

        guard let managed = windowController.captureFrontmostWindow() else {
            print("No frontmost window available. Make sure Accessibility permissions are granted and another app has a visible window.")
            return
        }

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            print("Window \(managed.windowId) is already managed in zone \(zoneIndex)")
            return
        }

        windowPlacementManager.placeNewWindow(managed)
        print("Captured window \(managed.windowId)")
    }

    func validateApplication(pid: pid_t) {
        let pruned = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "repl-command")
        if pruned.isEmpty {
            print("Validated pid \(pid): no destroyed windows detected")
        } else {
            print("Validated pid \(pid): pruned windows \(pruned)")
        }
    }

    // MARK: - Window Placement Logic




    private func indicatorFrame(for zone: Zone, descriptor: ScreenDescriptor) -> CGRect {
        let zoneFrame = descriptor.screenToCocoa(zone.frame).standardized
        let bounds = descriptor.cocoaBounds.standardized

        let indicatorHeight: CGFloat = 6
        let minWidth: CGFloat = 40
        let targetWidth = max(minWidth, zoneFrame.width / 3)
        let clampedWidth = min(targetWidth, zoneFrame.width)

        var originX = zoneFrame.midX - clampedWidth / 2
        originX = max(bounds.minX, min(originX, bounds.maxX - clampedWidth))

        let offset: CGFloat = 2
        // Always position the indicator inside the zone at the top with consistent offset
        // This ensures all zones have the same visual treatment
        var originY = zoneFrame.maxY - indicatorHeight - offset

        // Ensure the indicator stays within bounds
        if originY < bounds.minY {
            originY = bounds.minY
        }
        if originY + indicatorHeight > bounds.maxY {
            originY = bounds.maxY - indicatorHeight
        }

        return CGRect(x: originX, y: originY, width: clampedWidth, height: indicatorHeight)
    }

    internal func refreshIndicators() {
        // Refresh zone indicators
        var descriptors: [ZoneIndicatorDescriptor] = []

        for (screenId, context) in screenContexts {
            let screenDescriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                let frame = indicatorFrame(for: zone, descriptor: screenDescriptor)
                guard frame.width > 0, frame.height > 0 else {
                    continue
                }
                let descriptor = ZoneIndicatorDescriptor(
                    key: key,
                    cocoaFrame: frame,
                    isTargeted: key == targetedZoneKey
                )
                descriptors.append(descriptor)
            }
        }

        if descriptors.isEmpty {
            indicatorManager.tearDown()
        } else {
            indicatorManager.present(over: descriptors)
        }

        // Refresh add-zone indicators
        var addZoneDescriptors: [AddZoneIndicatorDescriptor] = []

        for (screenId, context) in screenContexts {
            let zoneCount = context.zoneController.allZones.count
            // Only show the indicator if there are fewer than 3 zones
            guard zoneCount < 3 else { continue }

            let screenDescriptor = context.descriptor
            let frame = addZoneIndicatorFrame(for: screenDescriptor)
            guard frame.width > 0, frame.height > 0 else {
                continue
            }
            let descriptor = AddZoneIndicatorDescriptor(
                screenId: screenId,
                frame: frame
            )
            addZoneDescriptors.append(descriptor)
        }

        if addZoneDescriptors.isEmpty {
            addZoneIndicatorManager.tearDown()
        } else {
            addZoneIndicatorManager.present(for: addZoneDescriptors)
        }
    }

    private func addZoneIndicatorFrame(for descriptor: ScreenDescriptor) -> CGRect {
        let bounds = descriptor.cocoaBounds.standardized

        // Width: match the height of zone indicators (6px)
        let indicatorWidth: CGFloat = 6

        // Height: 1/3 of screen height
        let indicatorHeight = bounds.height / 3

        // Position on the right edge, vertically centered
        let originX = bounds.maxX - indicatorWidth
        let originY = bounds.midY - indicatorHeight / 2

        return CGRect(x: originX, y: originY, width: indicatorWidth, height: indicatorHeight)
    }


    // MARK: - Synchronization

    /// Sync all windows to their zones, creating placeholders as needed
    internal func syncWindowsToZones(excluding excludedZones: Set<ZoneKey> = []) {
        let effectiveExcludedZones = excludedZones.union(dragExcludedZones)
        if isSyncingWindows {
            pendingSync = true
            pendingSyncExcludedZones.formUnion(effectiveExcludedZones)
            return
        }
        isSyncingWindows = true
        defer {
            isSyncingWindows = false
            if pendingSync {
                pendingSync = false
                let pendingExcluded = pendingSyncExcludedZones
                pendingSyncExcludedZones.removeAll()
                syncWindowsToZones(excluding: pendingExcluded)
            }
        }

        Logger.debug("Syncing windows to zones")

        let prunedWindowIds = windowController.pruneDestroyedExternalWindows()
        if !prunedWindowIds.isEmpty {
            for windowId in prunedWindowIds {
                removeWindowFromAllZones(windowId: windowId, reason: "sync-prune-destroyed")
            }
        }

        let existingWindows = windowController.allWindows
        var assignedWindowIds = Set<Int>()

        for screenId in screenOrder {
            guard let context = screenContexts[screenId],
                  let descriptor = descriptor(for: screenId) else {
                continue
            }
            let controller = context.zoneController

            for zone in controller.allZones {
                if let windowId = zone.windowId,
                   let managed = windowController.window(withId: windowId) {
                    let displayFrame = frameWithMargin(for: zone, in: controller)
                    windowController.moveWindow(managed, to: displayFrame, on: descriptor)
                    setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
                    assignedWindowIds.insert(windowId)
                }
            }
        }

        placeholderCoordinator.syncPlaceholders(
            existingWindows: existingWindows,
            screenOrder: screenOrder,
            excludedZones: effectiveExcludedZones,
            contextProvider: { screenId in
                guard let context = self.screenContexts[screenId],
                      let descriptor = self.descriptor(for: screenId) else {
                    return nil
                }
                let zoneController = context.zoneController
                return PlaceholderCoordinatorScreenContext(
                    descriptor: descriptor,
                    zoneController: zoneController,
                    displayFrameForZone: { zone in
                        self.frameWithMargin(for: zone, in: zoneController)
                    },
                    placeholderToZoneFrame: { frame, zone in
                        self.zoneFrame(fromContentFrame: frame, for: zone, in: context)
                    }
                )
            }
        )

        let placeholderCount = windowController.allWindows.filter { $0.isPlaceholder }.count

        // Calculate zone occupancy
        var occupiedZones = 0
        var emptyZones = 0
        for context in screenContexts.values {
            for zone in context.zoneController.allZones {
                if zone.isEmpty {
                    emptyZones += 1
                } else {
                    occupiedZones += 1
                }
            }
        }

        Logger.debug("Sync complete: assigned \(assignedWindowIds.count) window(s), placeholders \(placeholderCount), zones: \(occupiedZones) occupied, \(emptyZones) empty, excluded zones \(effectiveExcludedZones.count)")

        for window in windowController.allWindows where !window.isPlaceholder {
            if !assignedWindowIds.contains(window.windowId) {
                clearManagedWindowZone(window)
            }
        }

        targetedZoneManager.ensureTargetedZone(reason: "sync")
        refreshIndicators()
    }

    /// Compute the frame used to render content inside a zone, honoring the spec margin
    internal func frameWithMargin(for zone: Zone, in controller: ZoneController) -> CGRect {
        let margins = zoneMargins(for: zone, in: controller)

        var left = margins.left
        var right = margins.right
        var top = margins.top
        var bottom = margins.bottom

        var frame = zone.frame.standardized

        let horizontalTotal = left + right
        if horizontalTotal > frame.width && frame.width > 0 {
            let scale = frame.width / horizontalTotal
            left *= scale
            right *= scale
        }

        let verticalTotal = top + bottom
        if verticalTotal > frame.height && frame.height > 0 {
            let scale = frame.height / verticalTotal
            top *= scale
            bottom *= scale
        }

        frame.origin.x += left
        frame.origin.y += top
        frame.size.width = max(0, frame.size.width - (left + right))
        frame.size.height = max(0, frame.size.height - (top + bottom))

        return frame
    }

    private func zoneMargins(for zone: Zone, in controller: ZoneController) -> ZoneEdgeMargins {
        let frame = zone.frame.standardized
        let bounds = controller.layoutBounds.standardized
        let neighbors = controller.allZones.filter { $0 !== zone }

        let fullMargin = zoneMargin
        let sharedMargin = zoneMargin / 2
        let tolerance = edgeAlignmentTolerance

        func verticalOverlap(with other: CGRect) -> CGFloat {
            let standardized = other.standardized
            return min(frame.maxY, standardized.maxY) - max(frame.minY, standardized.minY)
        }

        func horizontalOverlap(with other: CGRect) -> CGFloat {
            let standardized = other.standardized
            return min(frame.maxX, standardized.maxX) - max(frame.minX, standardized.minX)
        }

        let hasLeftNeighbor = neighbors.contains {
            abs($0.frame.standardized.maxX - frame.minX) <= tolerance && verticalOverlap(with: $0.frame) > 0
        }
        let hasRightNeighbor = neighbors.contains {
            abs($0.frame.standardized.minX - frame.maxX) <= tolerance && verticalOverlap(with: $0.frame) > 0
        }
        let hasTopNeighbor = neighbors.contains {
            abs($0.frame.standardized.maxY - frame.minY) <= tolerance && horizontalOverlap(with: $0.frame) > 0
        }
        let hasBottomNeighbor = neighbors.contains {
            abs($0.frame.standardized.minY - frame.maxY) <= tolerance && horizontalOverlap(with: $0.frame) > 0
        }

        let leftMargin: CGFloat
        if abs(frame.minX - bounds.minX) <= tolerance {
            leftMargin = fullMargin
        } else if hasLeftNeighbor {
            leftMargin = sharedMargin
        } else {
            leftMargin = fullMargin
        }

        let rightMargin: CGFloat
        if abs(frame.maxX - bounds.maxX) <= tolerance {
            rightMargin = fullMargin
        } else if hasRightNeighbor {
            rightMargin = sharedMargin
        } else {
            rightMargin = fullMargin
        }

        let topMargin: CGFloat
        if abs(frame.minY - bounds.minY) <= tolerance {
            topMargin = fullMargin
        } else if hasTopNeighbor {
            topMargin = sharedMargin
        } else {
            topMargin = fullMargin
        }

        let bottomMargin: CGFloat
        if abs(frame.maxY - bounds.maxY) <= tolerance {
            bottomMargin = fullMargin
        } else if hasBottomNeighbor {
            bottomMargin = sharedMargin
        } else {
            bottomMargin = fullMargin
        }

        return ZoneEdgeMargins(
            top: max(0, topMargin),
            left: max(0, leftMargin),
            bottom: max(0, bottomMargin),
            right: max(0, rightMargin)
        )
    }


    /// Convert a content frame (placeholder or occupant window) back into the zone frame.
    private func zoneFrame(fromContentFrame frame: CGRect, for zone: Zone, in context: ScreenContext) -> CGRect {
        let margins = zoneMargins(for: zone, in: context.zoneController)

        var zoneFrame = frame.standardized
        zoneFrame.origin.x -= margins.left
        zoneFrame.origin.y -= margins.top
        zoneFrame.size.width += margins.left + margins.right
        zoneFrame.size.height += margins.top + margins.bottom
        zoneFrame = clamp(frame: zoneFrame, to: context.zoneController.layoutBounds)
        return zoneFrame
    }

    private func applyPlaceholderResize(zoneKey: ZoneKey, placeholderFrame: CGRect, finalize: Bool) {
        guard let context = screenContexts[zoneKey.screenId],
              let descriptor = descriptor(for: zoneKey.screenId) else {
            return
        }

        let screenContext = PlaceholderCoordinatorScreenContext(
            descriptor: descriptor,
            zoneController: context.zoneController,
            displayFrameForZone: { zone in
                self.frameWithMargin(for: zone, in: context.zoneController)
            },
            placeholderToZoneFrame: { frame, zone in
                self.zoneFrame(fromContentFrame: frame, for: zone, in: context)
            }
        )

        placeholderCoordinator.applyResize(zoneKey: zoneKey, placeholderFrame: placeholderFrame, context: screenContext, finalize: finalize)
    }

    private func clamp(frame: CGRect, to bounds: CGRect) -> CGRect {
        var normalized = frame.standardized

        let originX = max(bounds.minX, normalized.origin.x)
        let originY = max(bounds.minY, normalized.origin.y)
        let maxX = min(bounds.maxX, normalized.maxX)
        let maxY = min(bounds.maxY, normalized.maxY)

        normalized.origin = CGPoint(x: originX, y: originY)
        normalized.size.width = max(0, maxX - originX)
        normalized.size.height = max(0, maxY - originY)

        return normalized
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

    // MARK: - HotkeyServiceDelegate

    func hotkeyService(_ service: HotkeyService, didTrigger action: HotkeyService.Action) {
        switch action {
        case .addZone:
            Logger.debug("Hotkey add zone triggered")
        case .removeZone:
            Logger.debug("Hotkey remove zone triggered")
        case .captureTimeTravelLogs:
            Logger.debug("Hotkey capture time-travel logs triggered")
        }
        triggerShortcut(action)
    }

    // MARK: - SystemEventMonitorDelegate

    func systemEventMonitor(_ monitor: SystemEventMonitor, handleKeyEvent event: NSEvent) -> Bool {
        hotkeyService.handleLocalShortcut(event: event)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didActivate application: NSRunningApplication?) {
        if let previousPid = lastActiveApplicationPid {
            validationRetryManager.validateWindowsForApplication(pid: previousPid, reason: "workspace-activation-previous-app")
        }
        if let application {
            lastActiveApplicationPid = application.processIdentifier
        }
        handleApplicationEvent(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didLaunch application: NSRunningApplication?) {
        handleApplicationEvent(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didUnhide application: NSRunningApplication?) {
        handleApplicationEvent(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didDeactivate application: NSRunningApplication?) {
        handleApplicationStateChange(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didHide application: NSRunningApplication?) {
        handleApplicationStateChange(application)
    }

    func systemEventMonitor(_ monitor: SystemEventMonitor, didTerminate application: NSRunningApplication?) {
        handleApplicationTermination(application)
    }

    func systemEventMonitorWillSleep(_ monitor: SystemEventMonitor) {
        // Log current state before sleep
        var managedWindowCount = 0
        var placeholderCount = 0
        for window in windowController.allWindows {
            if window.isPlaceholder {
                placeholderCount += 1
            } else {
                managedWindowCount += 1
            }
        }
        Logger.debug("System will sleep - current state: \(managedWindowCount) managed windows, \(placeholderCount) placeholders")
    }

    func systemEventMonitorDidWake(_ monitor: SystemEventMonitor) {
        // Log initial state after wake
        var initialManagedCount = 0
        var initialPlaceholderCount = 0
        for window in windowController.allWindows {
            if window.isPlaceholder {
                initialPlaceholderCount += 1
            } else {
                initialManagedCount += 1
            }
        }
        Logger.debug("System did wake - initial state: \(initialManagedCount) managed windows, \(initialPlaceholderCount) placeholders - scheduling delayed window recapture")

        // First, validate and prune any destroyed windows from existing managed windows
        var pidsToValidate = Set<pid_t>()
        for window in windowController.allWindows {
            if case .accessibility(_, let pid, _) = window.backing {
                pidsToValidate.insert(pid)
            }
        }

        Logger.debug("Validating \(pidsToValidate.count) PIDs from existing managed windows")
        for pid in pidsToValidate {
            let pruned = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "system-wake-validation")
            if !pruned.isEmpty {
                Logger.debug("Pruned \(pruned.count) destroyed windows for pid \(pid)")
            }
        }

        // Force immediate sync to ensure placeholders are shown
        syncWindowsToZones()

        // Schedule window recapture after a delay to allow the Accessibility API to stabilize
        // We use multiple attempts with increasing delays to handle different wake scenarios
        scheduleWindowRecapture(delay: 0.5, reason: "wake")
        scheduleWindowRecapture(delay: 1.5, reason: "wake")
        scheduleWindowRecapture(delay: 3.0, reason: "wake")
    }

    private func scheduleWindowRecapture(delay: TimeInterval, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            Logger.debug("Attempting \(reason) recapture after \(delay) seconds")

            // Count how many windows we currently have
            var preCaptureManaged = 0
            var prePlaceholders = 0
            for window in self.windowController.allWindows {
                if window.isPlaceholder {
                    prePlaceholders += 1
                } else {
                    preCaptureManaged += 1
                }
            }

            // Recapture windows from all running applications
            let visibleBundleIds = self.bundleIdsWithVisibleWindows()
            var capturedCount = 0
            for application in NSWorkspace.shared.runningApplications {
                guard self.shouldManage(application: application, visibleBundleIds: visibleBundleIds) else {
                    continue
                }

                // Capture windows, allowing existing ones to be returned
                let capturedWindows = self.captureWindows(
                    for: application,
                    notifyDelegate: true,
                    allowExisting: true
                )
                if !capturedWindows.isEmpty {
                    capturedCount += capturedWindows.count
                    Logger.debug("Captured \(capturedWindows.count) windows for \(application.bundleIdentifier ?? "unknown") (pid \(application.processIdentifier))")
                }
            }

            // Only sync if we captured new windows
            if capturedCount > 0 {
                self.syncWindowsToZones()

                // Log the result
                var postCaptureManaged = 0
                var postPlaceholders = 0
                for window in self.windowController.allWindows {
                    if window.isPlaceholder {
                        postPlaceholders += 1
                    } else {
                        postCaptureManaged += 1
                    }
                }

                Logger.debug("\(reason.capitalized) recapture after \(delay)s: captured \(capturedCount) windows, managed: \(preCaptureManaged) -> \(postCaptureManaged), placeholders: \(prePlaceholders) -> \(postPlaceholders)")
            }
        }
    }

    func systemEventMonitorScreensDidChange(_ monitor: SystemEventMonitor) {
        Logger.debug("Screen configuration change notification received from AppKit")
        scheduleScreenTopologyRefresh(reason: "appkit-notification")
    }

    // MARK: - DisplayReconfigurationMonitorDelegate

    func displayMonitor(_ monitor: DisplayReconfigurationMonitor, didObserve event: DisplayReconfigurationMonitor.Event) {
        var components: [String] = []
        if event.isAdd { components.append("add") }
        if event.isRemove { components.append("remove") }
        if event.isMove { components.append("move") }
        if event.isEnabled { components.append("enabled") }
        if event.isDisabled { components.append("disabled") }
        if event.isConfigurationChange { components.append("config-change") }
        let description = components.isEmpty ? "unknown" : components.joined(separator: ",")
        Logger.debug("CGDisplay callback for id \(event.displayId) flags: \(description)")
        scheduleScreenTopologyRefresh(reason: "cgdisplay-\(description)", affectedDisplayIds: Set([event.displayId]))
    }

    private func suppressManualMoveHandling(for interval: TimeInterval, reason: String) {
        let newDeadline = Date().addingTimeInterval(interval)
        if manualMoveSuppressionDeadline == nil || newDeadline > manualMoveSuppressionDeadline! {
            manualMoveSuppressionDeadline = newDeadline
        }

        if dragDropCoordinator.isDragging {
            Logger.debug("Ending in-flight drag session due to manual move suppression (\(reason))")
            dragDropCoordinator.tearDownDragSession()
            syncWindowsToZones()
        }

        Logger.debug("Manual move handling suppressed for \(String(format: "%.2f", interval))s (reason: \(reason))")
    }

    private func shouldSuppressManualMoveHandling(windowId: Int, event: String) -> Bool {
        guard let deadline = manualMoveSuppressionDeadline else {
            return false
        }
        if Date() < deadline {
            Logger.debug("Suppressed manual \(event) for window \(windowId) while displays stabilize")
            return true
        }
        manualMoveSuppressionDeadline = nil
        return false
    }

    private func scheduleScreenTopologyRefresh(reason: String, affectedDisplayIds: Set<CGDirectDisplayID> = []) {
        suppressManualMoveHandling(for: manualMoveSuppressionDuration, reason: reason)
        if let existingReason = pendingScreenChangeReason {
            pendingScreenChangeReason = "\(existingReason),\(reason)"
        } else {
            pendingScreenChangeReason = reason
        }

        pendingScreenChangeDisplayIds.formUnion(affectedDisplayIds)

        pendingScreenChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let hintedIds = self.pendingScreenChangeDisplayIds
            let resolvedReason = self.pendingScreenChangeReason ?? reason
            self.pendingScreenChangeDisplayIds.removeAll()
            self.pendingScreenChangeReason = nil
            self.performScreenTopologyRefresh(reason: resolvedReason, hintedDisplayIds: hintedIds)
        }
        pendingScreenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + screenChangeDebounceInterval, execute: workItem)
    }

    private func performScreenTopologyRefresh(reason: String, hintedDisplayIds: Set<CGDirectDisplayID>) {
        Logger.debug("Performing screen topology refresh due to \(reason) (hinted display ids: \(hintedDisplayIds.count))")

        let screens = NSScreen.screens
        let rebuildResult = screenContextStore.rebuild(with: screens)

        if rebuildResult.addedDisplayIds.isEmpty,
           rebuildResult.removedContexts.isEmpty,
           !rebuildResult.orderChanged {
            Logger.debug("Screen topology unchanged after refresh request (\(reason))")
        }

        if !rebuildResult.addedDisplayIds.isEmpty {
            Logger.debug("Detected new display ids: \(rebuildResult.addedDisplayIds)")
        }

        if !rebuildResult.removedContexts.isEmpty {
            let removedIds = rebuildResult.removedContexts.map { $0.displayId }
            Logger.debug("Detected removed display ids: \(removedIds)")
        }

        if !rebuildResult.removedContexts.isEmpty {
            handleRemovedScreens(rebuildResult.removedContexts)
        }

        // Validate all external windows to drop stale references
        var pidsToValidate = Set<pid_t>()
        for window in windowController.allWindows {
            if case .accessibility(_, let pid, _) = window.backing {
                pidsToValidate.insert(pid)
            }
        }

        for pid in pidsToValidate {
            _ = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "screen-change")
        }

        targetedZoneManager.ensureTargetedZone(reason: "screens-changed")

        syncWindowsToZones()

        // Recapture after displays settle when meaningful changes occurred
        if !rebuildResult.addedDisplayIds.isEmpty || !rebuildResult.removedContexts.isEmpty || rebuildResult.orderChanged {
            scheduleWindowRecapture(delay: 0.5, reason: "screen-change")
            scheduleWindowRecapture(delay: 1.5, reason: "screen-change")
        }
    }

    private func handleRemovedScreens(_ removed: [ScreenContextStore.RebuildResult.RemovedContext]) {
        for entry in removed {
            placeholderCoordinator.clearMappingsForScreen(entry.displayId)
            let placeholders = windowController.allWindows.filter { $0.isPlaceholder && $0.screenDisplayId == entry.displayId }
            for placeholder in placeholders {
                Logger.debug("Closing placeholder \(placeholder.windowId) for removed screen \(entry.displayId)")
                windowController.closeWindow(placeholder)
                placeholderCoordinator.forget(windowId: placeholder.windowId)
            }
            let zoneCount = entry.context.zoneController.allZones.count
            Logger.debug("Handling removal of screen \(entry.context.descriptor.localizedName) [\(entry.displayId)] with \(zoneCount) zone(s)")

            for zone in entry.context.zoneController.allZones {
                guard let windowId = zone.windowId,
                      let managed = windowController.window(withId: windowId) else {
                    continue
                }

                if managed.isPlaceholder {
                    Logger.debug("Closing placeholder \(managed.windowId) tied to removed screen \(entry.displayId)")
                    windowController.closeWindow(managed)
                    placeholderCoordinator.forget(windowId: managed.windowId)
                    continue
                }

                Logger.debug("Reassigning window \(managed.windowId) from removed screen \(entry.displayId)")
                clearManagedWindowZone(managed)
                windowPlacementManager.placeNewWindow(managed, preferredScreenId: activeScreenId())
            }
        }
    }

    // MARK: - WindowCapturePipelineDelegate

    func capturePipeline(_ pipeline: WindowCapturePipeline, shouldManage application: NSRunningApplication) -> Bool {
        shouldManage(application: application)
    }

    // MARK: - PlaceholderCoordinatorDelegate

    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToShow placeholder: ManagedWindow,
        at frame: CGRect,
        on descriptor: ScreenDescriptor,
        isExcluded: Bool
    ) {
        let screenIndex = screenContextStore.screenIndex(for: descriptor.displayId) ?? ScreenContextStore.screenIndex(for: descriptor.displayId) ?? Int(descriptor.displayId)
        Logger.debug("Preparing to show placeholder window \(placeholder.windowId) for zone \(placeholder.zoneIndex ?? -1) on screen \(screenIndex) (excluded: \(isExcluded))")

        if isExcluded {
            Logger.debug("Bringing excluded placeholder \(placeholder.windowId) to front using orderFront")
            placeholder.appKitWindow?.orderFront(nil)
        } else {
            Logger.debug("Showing placeholder \(placeholder.windowId) using showWindow")
            windowController.showWindow(placeholder, at: frame, on: descriptor)
            windowController.moveWindow(placeholder, to: frame, on: descriptor)
        }
        placeholder.screenDisplayId = descriptor.displayId
        if let zoneIndex = placeholder.zoneIndex {
            setManagedWindow(placeholder, screenId: descriptor.displayId, zoneIndex: zoneIndex)
            let zoneKey = ZoneKey(screenId: descriptor.displayId, index: zoneIndex)
            if shouldRetarget(to: zoneKey) {
                targetedZoneManager.setTargetedZone(zoneKey, reason: "placeholder-shown")
            }
        }
    }

    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToHide placeholder: ManagedWindow,
        reason: PlaceholderCoordinator.HideReason
    ) {
        let screenIndex = placeholder.screenDisplayId.map { screenContextStore.screenIndex(for: $0) ?? ScreenContextStore.screenIndex(for: $0) ?? Int($0) } ?? -1
        Logger.debug("Preparing to hide placeholder window \(placeholder.windowId) for zone \(placeholder.zoneIndex ?? -1) on screen \(screenIndex) (reason: \(reason))")

        switch reason {
        case .replacedByWindow:
            Logger.debug("Closing placeholder \(placeholder.windowId) - replaced by actual window")
            windowController.closeWindow(placeholder)
        case .idle:
            Logger.debug("Hiding idle placeholder \(placeholder.windowId) using orderOut")
            placeholder.appKitWindow?.orderOut(nil)
        }
    }

    func placeholderCoordinator(_ coordinator: PlaceholderCoordinator, didResizeZone key: ZoneKey, finalize: Bool) {
        if finalize {
            let screenIndex = screenContextStore.screenIndex(for: key.screenId) ?? ScreenContextStore.screenIndex(for: key.screenId) ?? Int(key.screenId)
            Logger.debug("Placeholder for zone \(key.index) on screen \(screenIndex) resize finalized")
            syncWindowsToZones()
        } else {
            syncWindowsToZones(excluding: Set([key]))
        }
    }

    func placeholderCoordinator(_ coordinator: PlaceholderCoordinator, clearManagedZoneFor managed: ManagedWindow) {
        clearManagedWindowZone(managed)
    }

    // MARK: - TargetedZoneManagerDelegate

    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController? {
        screenContexts[screenId]?.zoneController
    }

    internal func removeWindowFromAllZones(windowId: Int, reason: String = "unspecified") {
        var removed = false
        var emptyZoneKey: ZoneKey?

        for (screenId, context) in screenContexts {
            if let zone = context.zoneController.zoneForWindow(windowId: windowId) {
                Logger.debug(
                    "Removing window \(windowId) from zone \(zone.index) on \(context.descriptor.localizedName) [\(screenId)] (reason: \(reason))"
                )
                context.zoneController.removeWindow(windowId: windowId)
                removed = true
                // Specification: Newly empty zones should become targeted when the current target is filled or has a higher index.
                emptyZoneKey = ZoneKey(screenId: screenId, index: zone.index)
            } else {
                context.zoneController.removeWindow(windowId: windowId)
            }
        }

        if let emptyZoneKey = emptyZoneKey, shouldRetarget(to: emptyZoneKey) {
            targetedZoneManager.setTargetedZone(emptyZoneKey, reason: "zone-became-empty")
        }

        if !removed, reason != "place-new-window" {
            Logger.debug("Requested removal of window \(windowId) from all zones but none were assigned (reason: \(reason))")
        }
    }

    /// Work around macOS missing focus notifications when an app's final managed window closes or minimizes.
    private func triggerActivationWorkaroundIfNeeded(pid: pid_t, excludingWindowIds: Set<Int>, reason: String) {
        guard pid != getpid() else {
            return
        }

        let otherManagedExists = windowController.allWindows.contains { candidate in
            guard case .accessibility(_, let otherPid, _) = candidate.backing,
                  otherPid == pid else {
                return false
            }
            if excludingWindowIds.contains(candidate.windowId) {
                return false
            }
            if candidate.isPlaceholder {
                return false
            }
            if candidate.isMinimized {
                return false
            }
            return true
        }

        if otherManagedExists {
            return
        }

        let targetApplication = NSRunningApplication(processIdentifier: pid)
        let latticeApplication = NSRunningApplication(processIdentifier: getpid())

        guard let targetApplication else {
            Logger.debug("Activation workaround skipped: unable to resolve NSRunningApplication for pid \(pid)")
            return
        }

        // Check if the target application is frontmost (as per updated specification)
        guard targetApplication.isActive else {
            Logger.debug("Activation workaround skipped: pid \(pid) is not frontmost (reason: \(reason))")
            return
        }

        Logger.debug("Activation workaround: activation sequence queued for pid \(pid) (reason: \(reason))")

        let performActivation = {
            if let latticeApplication {
                let selfResult = latticeApplication.activate(options: [.activateIgnoringOtherApps])
                Logger.debug("Activation workaround: activated LatticeTopology before pid \(pid) (result: \(selfResult))")
            } else {
                Logger.debug("Activation workaround: unable to resolve LatticeTopology application for pre-activation")
            }

            // Add small delay to allow OS to process the first activation
            DispatchQueue.main.asyncAfter(deadline: .now()) {
                let targetResult = targetApplication.activate(options: [.activateIgnoringOtherApps])
                Logger.debug("Activation workaround: reactivated pid \(pid) (result: \(targetResult))")
            }
        }

        if Thread.isMainThread {
            performActivation()
        } else {
            DispatchQueue.main.async(execute: performActivation)
        }
    }

    private func shouldRetarget(to candidate: ZoneKey) -> Bool {
        guard let currentKey = targetedZoneManager.targetedZoneKey else {
            return true
        }
        if !targetedZoneManager.zoneExists(currentKey) {
            return true
        }
        if !targetedZoneManager.isZoneEmpty(currentKey) {
            return true
        }
        if currentKey.index > candidate.index {
            return true
        }
        return false
    }

    private func zoneKey(for screenId: CGDirectDisplayID, index: Int) -> ZoneKey {
        ZoneKey(screenId: screenId, index: index)
    }

    internal func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?) {
        managed.screenDisplayId = screenId
        managed.zoneIndex = zoneIndex
    }

    internal func clearManagedWindowZone(_ managed: ManagedWindow) {
        managed.zoneIndex = nil
        managed.screenDisplayId = nil
    }

    internal func forgetPlaceholder(windowId: Int) {
        placeholderCoordinator.forget(windowId: windowId)
    }

    internal func detectScreenId(for managed: ManagedWindow) -> CGDirectDisplayID? {
        if let existing = managed.screenDisplayId, screenContexts[existing] != nil {
            return existing
        }

        guard let cocoaFrame = cocoaFrame(for: managed) else {
            return nil
        }

        var bestId: CGDirectDisplayID?
        var largestArea: CGFloat = 0

        for (screenId, context) in screenContexts {
            let intersection = cocoaFrame.intersection(context.descriptor.cocoaBounds)
            if intersection.isNull {
                continue
            }
            let area = intersection.width * intersection.height
            if area > largestArea {
                largestArea = area
                bestId = screenId
            }
        }

        if let bestId, largestArea > 0 {
            return bestId
        }

        for (screenId, context) in screenContexts {
            if context.descriptor.cocoaBounds.contains(cocoaFrame.origin) {
                return screenId
            }
        }

        return nil
    }

    private func cocoaFrame(for managed: ManagedWindow) -> CGRect? {
        switch managed.backing {
        case .appKit(let window):
            return window.frame
        case .accessibility(let element, _, _):
            guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
                  let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
                return nil
            }
            let accessibilityFrame = CGRect(origin: position, size: size)
            return CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: accessibilityFrame,
                primaryScreenBounds: primaryScreenBounds
            )
        }
    }

    // MARK: - ValidationRetryManagerDelegate

    func hasManagedWindows(for pid: pid_t) -> Bool {
        return windowController.allWindows.contains { window in
            if case .accessibility(_, let windowPid, _) = window.backing {
                return windowPid == pid
            }
            return false
        }
    }

    func pruneDestroyedWindowsForPid(_ pid: pid_t) -> [Int] {
        return windowController.pruneDestroyedWindowsForPid(pid)
    }

    func activationWorkaroundIfNeeded(for pid: pid_t, excludingWindowIds: Set<Int>, reason: String) {
        triggerActivationWorkaroundIfNeeded(pid: pid, excludingWindowIds: excludingWindowIds, reason: reason)
    }

    // MARK: - WindowControllerDelegate

    func windowFocusChanged(pid: pid_t) {
        // When focus changes in an application, validate its windows
        // This catches window closures that didn't fire destroy notifications
        validationRetryManager.validateWindowsForApplication(pid: pid, reason: "focus-changed")
    }

    func placeholderCloseRequested(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Placeholder close requested for zone \(zoneIndex) on screen \(screenIndex)")
        _ = performRemoveZone(at: zoneIndex, on: screenId, announce: false)
    }

    func placeholderActivated(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Placeholder activated for zone \(zoneIndex) on screen \(screenIndex)")
        targetedZoneManager.setTargetedZone(zoneKey(for: screenId, index: zoneIndex), reason: "placeholder-activated")
    }

    func zoneIndicatorActivated(_ key: ZoneKey) {
        let screenIndex = screenContextStore.screenIndex(for: key.screenId) ?? ScreenContextStore.screenIndex(for: key.screenId) ?? Int(key.screenId)
        Logger.debug("Zone indicator activated for zone \(key.index) on screen \(screenIndex)")
        targetedZoneManager.setTargetedZone(key, reason: "indicator-clicked")
    }

    // MARK: - AddZoneIndicatorManagerDelegate

    func addZoneIndicatorManager(_ manager: AddZoneIndicatorManager, didClickIndicatorFor screenId: CGDirectDisplayID) {
        let screenIndex = screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Add zone indicator clicked on screen \(screenIndex)")
        addZone(on: screenId)
    }

    func windowWillClose(windowId: Int) {
        Logger.debug("Window \(windowId) will close")
        let managed = windowController.window(withId: windowId)
        if let managed, managed.isPlaceholder {
            placeholderCoordinator.forget(windowId: windowId)
        }
        if dragDropCoordinator.currentDragWindowId == windowId {
            dragDropCoordinator.tearDownDragSession()
        }
        removeWindowFromAllZones(windowId: windowId, reason: "delegate-will-close")
        syncWindowsToZones()
        if let managed,
           case .accessibility(_, let pid, _) = managed.backing {
            triggerActivationWorkaroundIfNeeded(
                pid: pid,
                excludingWindowIds: Set([managed.windowId]),
                reason: "close"
            )
        }
    }

    func windowDidMiniaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did miniaturize")
        let managed = windowController.window(withId: windowId)
        if dragDropCoordinator.currentDragWindowId == windowId {
            dragDropCoordinator.tearDownDragSession()
        }
        removeWindowFromAllZones(windowId: windowId, reason: "delegate-did-miniaturize")
        syncWindowsToZones()
        if let managed,
           case .accessibility(_, let pid, _) = managed.backing {
            triggerActivationWorkaroundIfNeeded(
                pid: pid,
                excludingWindowIds: Set([managed.windowId]),
                reason: "miniaturize"
            )
        }
    }

    func windowDidDeminiaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did deminiaturize")
        guard let managed = windowController.window(withId: windowId) else { return }
        windowPlacementManager.placeNewWindow(managed)
    }

    func placeholderLiveResizeDidBegin(screenId: CGDirectDisplayID, zoneIndex: Int) {
        liveResizingZoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
    }

    func placeholderLiveResized(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect) {
        let key = ZoneKey(screenId: screenId, index: zoneIndex)
        guard liveResizingZoneKey == key else {
            return
        }

        applyPlaceholderResize(zoneKey: key, placeholderFrame: frame, finalize: false)
    }

    func placeholderLiveResizeDidEnd(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect) {
        let key = ZoneKey(screenId: screenId, index: zoneIndex)
        if liveResizingZoneKey == key {
            liveResizingZoneKey = nil
        }

        applyPlaceholderResize(zoneKey: key, placeholderFrame: frame, finalize: true)
    }

    func windowManualResizeDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "resize") {
            return
        }
        guard let screenId,
              let context = screenContexts[screenId],
              let managed = windowController.window(withId: windowId),
              let zoneIndex = managed.zoneIndex else {
            Logger.debug("Resize completed for window \(windowId) without a zone assignment")
            return
        }

        guard let zone = context.zoneController.zone(at: zoneIndex) else {
            Logger.debug("Zone \(zoneIndex) not found during resize for window \(windowId)")
            return
        }

        let zoneFrame = zoneFrame(fromContentFrame: frame, for: zone, in: context)
        guard context.zoneController.resizeZone(at: zoneIndex, to: zoneFrame, allowOccupied: true) else {
            Logger.debug("Failed to resize zone \(zoneIndex) from window \(windowId)")
            return
        }

        Logger.debug("Applied window-driven resize for zone \(zoneIndex) from window \(windowId)")
        syncWindowsToZones()
    }

    func windowManualMoveDidBegin(windowId: Int, frame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "move-begin") {
            return
        }
        guard let managed = windowController.window(withId: windowId), !managed.isPlaceholder else {
            return
        }

        let originZoneKey: ZoneKey?
        if let screenId = managed.screenDisplayId, let zoneIndex = managed.zoneIndex {
            originZoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
        } else {
            originZoneKey = nil
        }

        let originScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        dragDropCoordinator.beginDragSession(
            windowId: windowId,
            frame: frame,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId
        )
    }

    func windowManualMoveDidUpdate(windowId: Int, frame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "move-update") {
            return
        }
        dragDropCoordinator.updateDragSession(windowId: windowId, frame: frame)
    }

    func windowManualMoveDidEnd(windowId: Int, finalFrame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "move-end") {
            return
        }
        let result = dragDropCoordinator.endDragSession(windowId: windowId, finalFrame: finalFrame)

        if let displacedWindow = result.displacedWindow {
            windowPlacementManager.placeNewWindow(displacedWindow, preferredScreenId: result.preferredScreenId)
        }

        syncWindowsToZones()
    }

    func placeholderAllowedResizeAxes(screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderResizeAxes {
        guard let context = screenContexts[screenId],
              let zone = context.zoneController.zone(at: zoneIndex), zone.isEmpty else {
            return []
        }

        let zoneCount = context.zoneController.allZones.count
        return PlaceholderResizePolicy.allowedAxes(
            zoneIndex: zoneIndex,
            zoneCount: zoneCount,
            zoneIsEmpty: zone.isEmpty
        )
    }

    func windowController(_ controller: WindowController, didCaptureExternalWindow window: ManagedWindow) {
        windowPlacementManager.placeNewWindow(window)
    }

    func windowCreationFailedRetryNeeded(forPid pid: pid_t) {
        // When AXWindowCreated fires but we can't capture the window (likely due to .cannotComplete errors),
        // schedule a retry to attempt capturing windows for this PID again
        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        Logger.debug("Scheduling capture retry for pid \(pid) due to failed AXWindowCreated capture")
        capturePipeline.requestRetry(forPid: pid, bundleId: bundleId)
    }

    func screenDescriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor? {
        descriptor(for: screenId)
    }

    @discardableResult
    private func captureWindows(
        for application: NSRunningApplication,
        notifyDelegate: Bool,
        allowExisting: Bool
    ) -> [ManagedWindow] {
        let request = WindowCapturePipeline.CaptureRequest(
            application: application,
            notifyDelegate: notifyDelegate,
            allowExisting: allowExisting
        )
        return capturePipeline.capture(request)
    }

    // MARK: - Startup helpers

    private func prepareExistingApplicationWindows() {
        var windowsByScreen: [CGDirectDisplayID: [ManagedWindow]] = [:]
        let visibleBundleIds = bundleIdsWithVisibleWindows()

        for application in NSWorkspace.shared.runningApplications {
            guard shouldManage(application: application, visibleBundleIds: visibleBundleIds) else {
                continue
            }

            let windows = captureWindows(for: application, notifyDelegate: false, allowExisting: false)
            for window in windows {
                let resolvedScreenId = detectScreenId(for: window) ?? primaryScreenId
                guard screenContexts[resolvedScreenId] != nil else {
                    continue
                }
                windowsByScreen[resolvedScreenId, default: []].append(window)
            }
        }

        for (screenId, windows) in windowsByScreen {
            guard let context = screenContexts[screenId] else {
                continue
            }

            let sortedWindows = windows.sorted { lhs, rhs in
                let leftX = screenMinX(for: lhs, descriptor: context.descriptor)
                let rightX = screenMinX(for: rhs, descriptor: context.descriptor)
                if leftX == rightX {
                    return lhs.windowId < rhs.windowId
                }
                return leftX < rightX
            }

            let desiredZoneCount = max(1, min(windows.count, 3))
            let removedWindowIds = context.zoneController.setZoneCount(to: desiredZoneCount)

            // Clear placeholder mappings when zone count changes to prevent stale mappings
            if !removedWindowIds.isEmpty {
                placeholderCoordinator.clearMappingsForScreen(screenId)
            }

            for removedId in removedWindowIds {
                if let removedWindow = windowController.window(withId: removedId) {
                    clearManagedWindowZone(removedWindow)
                    windowController.minimizeWindow(removedWindow)
                }
            }

            let managedCandidates = sortedWindows.prefix(desiredZoneCount)
            let excessWindows = sortedWindows.dropFirst(desiredZoneCount)

            for window in managedCandidates {
                windowPlacementManager.placeNewWindow(window, preferredScreenId: screenId)
            }

            for window in excessWindows {
                clearManagedWindowZone(window)
                windowController.minimizeWindow(window)
            }
        }

        for (screenId, context) in screenContexts where windowsByScreen[screenId] == nil {
            context.zoneController.setZoneCount(to: 1)
        }
    }

    /// Compute the left edge of a window in screen coordinates for ordering.
    private func screenMinX(for managed: ManagedWindow, descriptor: ScreenDescriptor) -> CGFloat {
        guard let cocoaFrame = cocoaFrame(for: managed) else {
            return .greatestFiniteMagnitude
        }
        return descriptor.cocoaToScreen(cocoaFrame).minX
    }

    private func handleApplicationEvent(_ application: NSRunningApplication?) {
        guard let application else {
            return
        }

        guard shouldManage(application: application) else {
            return
        }

        scheduleCapture(for: application, delay: 0.0)
        scheduleCapture(for: application, delay: 0.4)
    }

    private func handleApplicationStateChange(_ application: NSRunningApplication?) {
        guard let application else {
            return
        }

        guard shouldManage(application: application) else {
            return
        }

        // When an application changes state (deactivate/hide), validate all its windows
        // This catches window closures that didn't fire destroy notifications
        validationRetryManager.validateWindowsForApplication(pid: application.processIdentifier, reason: "workspace-state-change")
    }

    private func handleApplicationTermination(_ application: NSRunningApplication?) {
        guard let application else {
            Logger.debug("NSWorkspace notification received: didTerminateApplication (no application payload)")
            return
        }

        let name = application.localizedName ?? "Unknown App"
        var details = "\(name), pid \(application.processIdentifier)"
        if let bundleId = application.bundleIdentifier {
            details += ", bundle \(bundleId)"
        }
        Logger.debug("NSWorkspace notification received: didTerminateApplication (\(details))")

        capturePipeline.cancelRetry(forPid: application.processIdentifier)

        // When an application terminates, remove all of its managed windows immediately
        let removedWindowIds = windowController.removeAllWindows(forPid: application.processIdentifier)
        if removedWindowIds.isEmpty {
            Logger.debug("Application terminated, but no managed windows were associated with pid \(application.processIdentifier)")
            return
        }

        Logger.debug("Application terminated, pruned \(removedWindowIds.count) windows")
        validationRetryManager.cancelValidationRetry(for: application.processIdentifier)
        for windowId in removedWindowIds {
            if dragDropCoordinator.currentDragWindowId == windowId {
                dragDropCoordinator.tearDownDragSession()
            }
            removeWindowFromAllZones(windowId: windowId, reason: "application-termination")
        }
        syncWindowsToZones()
    }

    private func scheduleCapture(for application: NSRunningApplication, delay: TimeInterval) {
        let pid = application.processIdentifier
        let originalBundleId = application.bundleIdentifier  // Capture bundle ID to verify identity

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard let refreshedApplication = NSRunningApplication(processIdentifier: pid) else { return }

            // Verify the PID still belongs to the same application
            if let originalBundleId = originalBundleId,
               let refreshedBundleId = refreshedApplication.bundleIdentifier,
               originalBundleId != refreshedBundleId {
                Logger.debug("PID \(pid) has been reused by different app (was \(originalBundleId), now \(refreshedBundleId)), aborting capture")
                return
            }

            guard self.shouldManage(application: refreshedApplication) else { return }

            _ = self.captureWindows(
                for: refreshedApplication,
                notifyDelegate: true,
                allowExisting: false
            )
        }
    }

    private func shouldManage(application: NSRunningApplication, visibleBundleIds: Set<String>? = nil) -> Bool {
        guard !application.isTerminated else {
            return false
        }
        if application.processIdentifier == getpid() {
            return false
        }
        guard let bundleId = application.bundleIdentifier else {
            return false
        }
        if let visibleBundleIds = visibleBundleIds,
           !visibleBundleIds.contains(bundleId) {
            return false
        }
        if configuration.ignoredBundleIdentifiers.contains(bundleId) {
            return false
        }
        if application.activationPolicy != .regular {
            return false
        }
        if isXpcOrHelperProcess(application) {
            return false
        }
        return true
    }

    private func bundleIdsWithVisibleWindows() -> Set<String> {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var bundleIds: Set<String> = []
        for info in windowInfoList {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: ownerPid),
                  let bundleId = app.bundleIdentifier else {
                continue
            }
            bundleIds.insert(bundleId)
        }
        return bundleIds
    }

    private func isXpcOrHelperProcess(_ application: NSRunningApplication) -> Bool {
        guard let url = application.bundleURL else {
            return false
        }

        let path = url.path
        return path.hasSuffix(".xpc") ||
            path.contains("/Contents/XPCServices/") ||
            path.contains(".xpc/")
    }

    private func triggerShortcut(_ action: HotkeyService.Action) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch action {
            case .addZone:
                self.addZone()
            case .removeZone:
                let screenId = self.activeScreenId()
                guard let removalIndex = self.zoneIndexForShortcutRemoval(on: screenId) else { return }
                if let context = self.screenContexts[screenId],
                   let zone = context.zoneController.zone(at: removalIndex) {
                    let targetedMatch = (self.targetedZoneKey?.screenId == screenId) && (self.targetedZoneKey?.index == removalIndex)
                    let screenIndex = self.screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
                    Logger.debug(
                        "Shortcut remove about to remove zone \(removalIndex) on \(context.descriptor.localizedName) " +
                        "[\(screenIndex)] (empty: \(zone.isEmpty), targeted: \(targetedMatch), window: \(zone.windowId.map(String.init) ?? "none"))"
                    )
                } else {
                    let screenIndex = self.screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
                    Logger.debug("Shortcut remove selected zone \(removalIndex) on screen \(screenIndex), but zone details unavailable")
                }
                _ = self.performRemoveZone(at: removalIndex, on: screenId, announce: true)
            case .captureTimeTravelLogs:
                self.captureTimeTravelLogs(triggerReason: "shortcut")
            }
        }
    }

    private func captureTimeTravelLogs(triggerReason: String) {
        let captureTime = Date()
        let cwd = FileManager.default.currentDirectoryPath
        let destinationURL = URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("time_travel_log.txt", isDirectory: false)
        let success = Logger.dumpRecentLogs(
            destinationURL: destinationURL,
            captureTimestamp: captureTime
        )
        if success {
            Logger.debug("Time-travel logs captured at \(destinationURL.path) (reason: \(triggerReason))")
        } else {
            Logger.debug("Time-travel log capture failed (reason: \(triggerReason))")
        }
    }

    private func zoneIndexForShortcutRemoval(on screenId: CGDirectDisplayID) -> Int? {
        guard let context = screenContexts[screenId] else {
            return nil
        }

        let zones = context.zoneController.allZones
        guard zones.count > 1 else {
            return nil
        }

        let activeIndices = activeZoneIndices(on: screenId)
        let activeList = activeIndices.sorted()
        Logger.debug(
            "Shortcut remove evaluating screen \(context.descriptor.localizedName) [\(screenId)] " +
            "with active zone indices: \(activeList)"
        )

        let targetedIndex: Int?
        if let targetedKey = targetedZoneKey, targetedKey.screenId == screenId {
            targetedIndex = targetedKey.index
        } else {
            targetedIndex = nil
        }

        let candidates = zones.filter { zone in
            return !activeIndices.contains(zone.index)
        }

        guard !candidates.isEmpty else {
            Logger.debug(
                "Shortcut remove found no removable zones on \(context.descriptor.localizedName) " +
                "[\(screenId)] (active zones: \(activeList), total zones: \(zones.count))"
            )
            return nil
        }

        let orderedCandidates = candidates.sorted { lhs, rhs in
            removalPriorityKey(for: lhs, targetedIndex: targetedIndex) <
                removalPriorityKey(for: rhs, targetedIndex: targetedIndex)
        }

        let description = orderedCandidates.map { zone -> String in
            let priority = removalPriorityKey(for: zone, targetedIndex: targetedIndex)
            let targetedFlag = (targetedIndex == zone.index)
            return "zone \(zone.index){empty:\(zone.isEmpty), targeted:\(targetedFlag), window:\(zone.windowId.map(String.init) ?? "none"), priority:\(priority)}"
        }.joined(separator: ", ")

        if let selected = orderedCandidates.first {
            Logger.debug(
                "Shortcut remove selected zone \(selected.index) on \(context.descriptor.localizedName) " +
                "[\(screenId)] from candidates [\(description)]"
            )
            return selected.index
        } else {
            Logger.debug(
                "Shortcut remove unable to choose among candidates on \(context.descriptor.localizedName) " +
                "[\(screenId)], descriptions: [\(description)]"
            )
            return nil
        }
    }

    private func removalPriorityKey(for zone: Zone, targetedIndex: Int?) -> (Int, Int, Int) {
        let emptinessRank = zone.isEmpty ? 0 : 1
        let targetedRank = (targetedIndex == zone.index) ? 1 : 0
        let indexRank = -zone.index
        return (emptinessRank, targetedRank, indexRank)
    }

    private func activeZoneIndices(on screenId: CGDirectDisplayID) -> Set<Int> {
        let screenName = screenContexts[screenId]?.descriptor.localizedName ?? "Unknown Screen"

        if let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPid != getpid(),
           let managed = windowController.focusedWindowIfTracked(pid: frontmostPid),
           !managed.isPlaceholder,
           let zoneIndex = managed.zoneIndex,
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            Logger.debug(
                "activeZoneIndices: using frontmost pid \(frontmostPid) -> zone \(zoneIndex) on \(screenName) [\(screenId)]"
            )
            return [zoneIndex]
        }

        if let lastPid = lastActiveApplicationPid,
           let managed = windowController.focusedWindowIfTracked(pid: lastPid),
           !managed.isPlaceholder,
           let zoneIndex = managed.zoneIndex,
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            Logger.debug(
                "activeZoneIndices: using last active pid \(lastPid) -> zone \(zoneIndex) on \(screenName) [\(screenId)]"
            )
            return [zoneIndex]
        }

        guard let context = screenContexts[screenId] else {
            return []
        }

        var candidatePids: Set<pid_t> = []
        if let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPid != getpid() {
            candidatePids.insert(frontmostPid)
        }
        if let lastPid = lastActiveApplicationPid,
           lastPid != getpid() {
            candidatePids.insert(lastPid)
        }

        var indices: Set<Int> = []
        for zone in context.zoneController.allZones {
            guard let windowId = zone.windowId,
                  let managedWindow = windowController.window(withId: windowId),
                  !managedWindow.isPlaceholder,
                  (managedWindow.screenDisplayId ?? detectScreenId(for: managedWindow)) == screenId else {
                if let windowId = zone.windowId,
                   let managedWindow = windowController.window(withId: windowId) {
                    let hasScreen = (managedWindow.screenDisplayId ?? detectScreenId(for: managedWindow)) != nil
                    Logger.debug(
                        "activeZoneIndices: skipping zone \(zone.index) on \(screenName) [\(screenId)] " +
                        "for window \(windowId) (placeholder: \(managedWindow.isPlaceholder), hasScreen: \(hasScreen))"
                    )
                } else if zone.windowId != nil {
                    Logger.debug(
                        "activeZoneIndices: no managed window for id \(zone.windowId!) in zone \(zone.index) on \(screenName) [\(screenId)]"
                    )
                }
                continue
            }

            switch managedWindow.backing {
            case .accessibility(_, let pid, _):
                if candidatePids.contains(pid) {
                    indices.insert(zone.index)
                } else {
                    Logger.debug(
                        "activeZoneIndices: window \(windowId) pid \(pid) not in candidate pid set \(candidatePids) " +
                        "for zone \(zone.index) on \(screenName) [\(screenId)]"
                    )
                }
            case .appKit(let nsWindow):
                if nsWindow.isKeyWindow {
                    indices.insert(zone.index)
                } else {
                    Logger.debug(
                        "activeZoneIndices: AppKit window \(windowId) in zone \(zone.index) is not key on \(screenName) [\(screenId)]"
                    )
                }
            }
        }
        Logger.debug(
            "activeZoneIndices: resolved indices \(indices.sorted()) for \(screenName) [\(screenId)] with candidate pids \(candidatePids)"
        )
        return indices
    }

    // MARK: - Inspection

    func listZones() {
        print("\nCurrent zones:")
        for screenId in screenOrder {
            guard let context = screenContexts[screenId] else { continue }
            // Convert internal display ID to user-friendly index for display
            let screenIndex = screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId)
            let screenIdentifier = screenIndex.map { String($0) } ?? String(screenId)
            print("  Screen \(context.descriptor.localizedName) [\(screenIdentifier)]:")
            for zone in context.zoneController.allZones {
                let windowInfo = zone.windowId.map { "window \($0)" } ?? "empty"
                print("    Zone \(zone.index): \(windowInfo), frame: \(zone.frame)")
            }
        }
        print("")
    }

    func printManagedWindows() {
        let windows = windowController.allWindows.sorted { $0.windowId < $1.windowId }
        print("\nManaged windows:")
        guard !windows.isEmpty else {
            print("  (none)")
            print("")
            return
        }

        for window in windows {
            let info = windowInfoJSON(windowId: window.windowId)
            let type = info["type"] as? String ?? "unknown"
            let zoneIndex = info["zone_index"] as? Int

            let screenId: CGDirectDisplayID? = {
                if let value = info["screen_display_id"] {
                    if let intValue = value as? Int {
                        return CGDirectDisplayID(intValue)
                    } else if let uintValue = value as? UInt32 {
                        return uintValue
                    }
                }
                return window.screenDisplayId
            }()

            let screenName = screenId.flatMap { descriptor(for: $0)?.localizedName } ?? "unknown screen"
            let pid = info["pid"] as? Int
            let appName = info["application_name"] as? String ?? "<unknown>"
            let bundleId = info["bundle_identifier"] as? String ?? "<unknown>"

            let zoneDescription: String
            if let zoneIndex, let screenId {
                zoneDescription = "zone \(zoneIndex) on \(screenName) [\(Int(screenId))]"
            } else if let zoneIndex {
                zoneDescription = "zone \(zoneIndex)"
            } else {
                zoneDescription = "unassigned"
            }

            let pidDescription: String
            if let pid {
                pidDescription = "pid \(pid) (\(appName), \(bundleId))"
            } else {
                pidDescription = "(no pid)"
            }

            print("  Window \(window.windowId): \(type), \(pidDescription), \(zoneDescription)")
        }
        print("")
    }

    func relayout() {
        for context in screenContexts.values {
            context.zoneController.relayout()
        }
        syncWindowsToZones()
        print("Layouts recalculated")
    }

    func windowInfo(windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        let type: String
        if managed.isPlaceholder {
            type = "placeholder"
        } else {
            switch managed.backing {
            case .appKit:
                type = "test"
            case .accessibility:
                type = "external"
            }
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
            descriptor(for: id)
        }
        let actualFrame: CGRect
        if let screenDescriptor {
            actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: screenDescriptor)
        } else if let fallback = windowController.actualFrameInScreenCoordinates(for: managed) {
            actualFrame = fallback
        } else {
            actualFrame = .zero
        }

        print("\nWindow \(windowId):")
        print("  Type: \(type)")

        var owningPid: pid_t?
        switch managed.backing {
        case .appKit:
            owningPid = getpid()
        case .accessibility(_, let pid, _):
            owningPid = pid
        }

        if let pid = owningPid {
            if let application = NSRunningApplication(processIdentifier: pid) ?? (pid == getpid() ? NSRunningApplication.current : nil) {
                let name = application.localizedName ?? "<unknown>"
                let bundle = application.bundleIdentifier ?? "<unknown>"
                print("  PID: \(pid) (\(name), \(bundle))")
            } else {
                print("  PID: \(pid)")
            }
        } else {
            print("  PID: unknown")
        }
        if let screenId, let screenDescriptor {
            let screenIndex = screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId)
            let screenIdentifier = screenIndex.map { String($0) } ?? String(screenId)
            print("  Screen: \(screenDescriptor.localizedName) [\(screenIdentifier)]")
        } else {
            print("  Screen: unknown")
        }
        print("  Zone: \(managed.zoneIndex?.description ?? "none (minimized)")")
        print("  Actual frame: \(actualFrame)")

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex) {
            print("  Zone frame: \(zone.frame)")
        }
        print("")
    }

    func printFrames() {
        print("\nAll window frames:")
        for window in windowController.allWindows {
            let type: String
            if window.isPlaceholder {
                type = "placeholder"
            } else {
                switch window.backing {
                case .appKit:
                    type = "test"
                case .accessibility:
                    type = "external"
                }
            }
            let screenId = window.screenDisplayId ?? detectScreenId(for: window)
            let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
                descriptor(for: id)
            }
            let actualFrame: CGRect
            if let screenDescriptor {
                actualFrame = windowController.actualFrameInScreenCoordinates(for: window, on: screenDescriptor)
            } else if let fallback = windowController.actualFrameInScreenCoordinates(for: window) {
                actualFrame = fallback
            } else {
                actualFrame = .zero
            }
            if let screenId, let screenDescriptor {
                let screenIndex = screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId)
                let screenIdentifier = screenIndex.map { String($0) } ?? String(screenId)
                print("  Window \(window.windowId) (\(type)) on \(screenDescriptor.localizedName) [\(screenIdentifier)]: \(actualFrame)")
            } else {
                print("  Window \(window.windowId) (\(type)) on unknown screen: \(actualFrame)")
            }
        }
        print("")
    }

}
